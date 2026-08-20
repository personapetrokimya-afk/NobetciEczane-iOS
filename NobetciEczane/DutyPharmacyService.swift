import Foundation
import CoreLocation

/// eczaneler.gen.tr üzerinden GÜNCEL nöbetçi eczane verisi çeker.
///
/// v2 değişiklikleri:
/// - Önce ilçe sayfası (`/nobetci-izmir-bornova`), olmazsa il sayfası denenir.
/// - www / www'suz host ve yeniden deneme (retry) ile geçici hatalar tolere edilir.
/// - Sayfada 3 günlük nöbet listesi olduğu için SADECE ilk (bugünkü) tablo okunur.
/// - Tablo (`<tr>/<td>`) yapısı öncelikli, eski blok/regex yöntemi yedek olarak kalır.
/// - Hata mesajları artık HTTP kodu / sistem hatasını da gösterir (teşhis için).
struct DutyPharmacyService {

    // MARK: - Session

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral

        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false          // Ağ yoksa 25 sn beklemek yerine hemen hata ver.

        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil

        config.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
                "Version/18.0 Mobile/15E148 Safari/604.1",
            "Accept":
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "tr-TR,tr;q=0.9,en-US;q=0.7,en;q=0.6",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "Upgrade-Insecure-Requests": "1"
        ]

        self.session = URLSession(configuration: config)
    }


    // MARK: - Public

    /// Uygulamanın ana akışı:
    /// 1. Telefonun güncel konumu alınır.
    /// 2. Konumdan ŞEHİR belirlenir.
    /// 3. O şehrin bugünkü nöbetçi listesi TÜM KAYNAKLARDAN paralel çekilip birleştirilir.
    /// 4. Liste, telefona en yakın eczaneden en uzağa doğru sıralanıp döndürülür.
    func fetchNearest(to location: CLLocation) async throws -> [Pharmacy] {

        let placemark = try await reverseGeocode(location)

        guard let city = detectCity(from: placemark),
              !city.isEmpty else {
            throw ServiceError.cityNotFound
        }

        let district = detectDistrict(from: placemark)
        let citySlug = slug(city)

        log("📍 Şehir: \(city) (\(citySlug)) / İlçe: \(district ?? "-")")

        // Önce İLÇE (en dar ve en isabetli liste), sonra il geneli.
        // İkisi birleşip mesafeye göre sıralanır: ilçedekiler doğal olarak başa gelir,
        // ilçede nöbetçi yoksa il genelindeki en yakınlar listelenir.
        var result = CrossCheckResult()

        if let district,
           !district.isEmpty {

            result = await fetchCrossChecked(
                citySlug: citySlug,
                districtSlug: slug(district),
                districtName: district
            )
        }

        let cityWide = await fetchCrossChecked(
            citySlug: citySlug,
            districtSlug: nil,
            districtName: nil
        )

        if result.isEmpty {
            result = cityWide
        } else if !cityWide.isEmpty {
            result.pharmacies = merge(result.pharmacies, with: cityWide.pharmacies)
            for source in cityWide.succeeded where !result.succeeded.contains(source) {
                result.succeeded.append(source)
            }
        } else {
            result.failures.append(contentsOf: cityWide.failures)
        }

        guard !result.isEmpty else {
            throw ServiceError.sourceUnavailable(
                detail: result.failures.isEmpty
                    ? "tüm kaynaklar boş döndü"
                    : result.failures.joined(separator: " | ")
            )
        }

        log("✅ Kaynaklar: \(result.succeeded.joined(separator: ", ")) — \(result.pharmacies.count) kayıt")

        // Koordinatı hiçbir kaynaktan çıkmayan kayıtlar adresten tamamlanır.
        let enriched = await enrichMissingCoordinates(result.pharmacies, city: city)

        // En yakından en uzağa.
        return sort(enriched, around: location)
    }


    /// Arayüz açılır açılmaz "şu an buradasın" bilgisini gösterebilsin diye
    /// konumdan il ve ilçe birlikte çözümlenir.
    func detectPlace(for location: CLLocation) async -> (city: String, district: String?)? {

        guard let placemark = try? await reverseGeocode(location),
              let city = detectCity(from: placemark),
              !city.isEmpty else {
            return nil
        }

        return (city, detectDistrict(from: placemark))
    }


    // MARK: - Loading

    func loadPharmacies(
        city: String,
        district: String?
    ) async throws -> [Pharmacy] {

        var lastError: ServiceError = .sourceUnavailable(detail: "bilinmiyor")

        for url in candidateURLs(city: city, district: district) {

            do {
                let html = try await fetchHTML(from: url)

                let todaySection = extractTodaySection(from: html)

                var found = parseTableRows(
                    from: todaySection,
                    fallbackDistrict: district
                )

                if found.isEmpty {
                    found = parseGenericBlocks(
                        from: todaySection,
                        fallbackDistrict: district
                    )
                }

                log("💊 \(url.absoluteString) -> \(found.count) kayıt")

                if !found.isEmpty {
                    return removeDuplicates(found)
                }

                lastError = .noDutyPharmacyFound

            } catch let error as ServiceError {
                lastError = error
                log("❌ \(url.absoluteString) -> \(error.diagnosticText)")
            }
        }

        throw lastError
    }


    /// Aynı sayfa için denenecek adresler. İlki başarısızsa sıradaki denenir.
    func candidateURLs(
        city: String,
        district: String?
    ) -> [URL] {

        let citySlug = slug(city)

        var paths: [String] = []

        if let district,
           !district.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let districtSlug = slug(district)
            if !districtSlug.isEmpty {
                paths.append("nobetci-\(citySlug)-\(districtSlug)")
            }
        } else {
            paths.append("nobetci-\(citySlug)")
        }

        let hosts = [
            "https://www.eczaneler.gen.tr",
            "https://eczaneler.gen.tr"
        ]

        var urls: [URL] = []

        for path in paths {
            for host in hosts {
                if let url = URL(string: "\(host)/\(path)") {
                    urls.append(url)
                }
            }
        }

        return urls
    }


    func fetchHTML(from url: URL) async throws -> String {

        var lastDetail = "bilinmiyor"

        // Geçici ağ hataları için 2 deneme.
        for attempt in 1...2 {

            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 15
            )

            request.httpMethod = "GET"
            request.setValue(
                "https://www.eczaneler.gen.tr/",
                forHTTPHeaderField: "Referer"
            )

            do {
                let (data, response) = try await session.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    throw ServiceError.invalidResponse
                }

                guard (200...299).contains(http.statusCode) else {
                    lastDetail = "HTTP \(http.statusCode) — \(url.host ?? "")"
                    if http.statusCode == 404 { break }   // Yanlış slug: tekrar denemenin anlamı yok.
                    throw ServiceError.sourceUnavailable(detail: lastDetail)
                }

                guard !data.isEmpty else {
                    throw ServiceError.invalidResponse
                }

                guard let html =
                        String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1),
                      !html.isEmpty else {
                    throw ServiceError.invalidResponse
                }

                log("🌐 \(url.absoluteString) — \(data.count) byte")

                return html

            } catch let error as ServiceError {
                lastDetail = error.diagnosticText

            } catch let error as URLError {
                lastDetail = "\(error.code.rawValue) \(error.localizedDescription)"

            } catch {
                lastDetail = error.localizedDescription
            }

            if attempt == 1 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        throw ServiceError.sourceUnavailable(detail: lastDetail)
    }


    // MARK: - Bugünkü nöbet bölümü

    /// Sayfada birden çok güne ait nöbet listesi bulunur; her dönem şu tarz bir
    /// başlıkla ayrılır:
    ///
    ///   "19 Ağustos Çarşamba akşamından 20 Ağustos Perşembe sabahına kadar"
    ///
    /// ÖNEMLİ: Doğru dönem, sayfadaki SIRAYA göre (ilk bölüm) değil, CİHAZ TARİHİNE
    /// göre seçilir. Site listede dünü de yayınladığından "ilk bölüm = bugün"
    /// varsayımı, sabahtan sonra DÜNKÜ nöbeti gösteriyordu. Bunun yerine başlıktaki
    /// başlangıç tarihi, `currentDutyDateKey()` ile hesaplanan bugünün nöbet tarihine
    /// eşleşen bölüm alınır. Eşleşme yoksa (sayfa o günü yayınlamıyorsa) ilk bölüme düşülür.
    func extractTodaySection(from html: String) -> String {

        let markers = ranges(of: #"(?i)akşam"#, in: html)

        guard !markers.isEmpty else {
            return firstTableWithRows(in: html) ?? html
        }

        // Her dönem başlığının anahtarını ("19 agustos") ve sayfadaki başlangıç
        // konumunu topla. Sayfada birden çok güne ait liste bulunur; hangisinin
        // BUGÜN geçerli olduğunu SAYFADAKİ SIRAYA göre değil, CİHAZ TARİHİNE göre
        // seçeriz. Eski davranış "ilk bölüm = bugün" varsayıyordu; site listede
        // dünü de yayınladığı için sabahtan sonra DÜNKÜ nöbeti gösteriyordu.
        struct DutySection {
            var key: String
            var start: String.Index
        }

        var sections: [DutySection] = []

        for marker in markers {

            let windowStart = html.index(
                marker.lowerBound,
                offsetBy: -160,
                limitedBy: html.startIndex
            ) ?? html.startIndex

            let key = periodKey(from: String(html[windowStart..<marker.lowerBound]))

            // Aynı dönem başlığı birden çok tabloda tekrar edebilir; yalnızca
            // anahtarın DEĞİŞTİĞİ noktaları yeni bölüm sınırı sayarız.
            if let last = sections.last, last.key == key {
                continue
            }

            sections.append(DutySection(key: key, start: windowStart))
        }

        guard !sections.isEmpty else {
            return firstTableWithRows(in: html) ?? html
        }

        // Bir bölümün gövdesi: kendi başlangıcından bir sonraki bölümün başlangıcına.
        func body(at index: Int) -> String {
            let start = sections[index].start
            let end = index + 1 < sections.count ? sections[index + 1].start : html.endIndex
            return String(html[start..<end])
        }

        // 1) Cihaz tarihine (İstanbul saati + sabah devri) denk gelen dönemi seç.
        let targetKey = currentDutyDateKey()

        if !targetKey.isEmpty,
           let index = sections.firstIndex(where: { $0.key == targetKey }) {
            return body(at: index)
        }

        // 2) Tarih eşleşmezse (sayfa o günü henüz/artık yayınlamıyorsa) ilk dönem.
        return body(at: 0)
    }


    /// Cihaz saatine göre BUGÜN geçerli olan nöbet döneminin başlangıç tarihini
    /// "20 agustos" biçiminde (periodKey ile aynı normalizasyon) döndürür.
    ///
    /// Nöbet "akşamından sabahına" sürdüğü için sabah devir saatinden ÖNCE hâlâ
    /// dün akşam başlayan nöbet geçerlidir; bu yüzden erken saatlerde hedef tarih
    /// bir gün geri alınır. Böylece gece 03:00'te de doğru (o an açık olan) nöbet
    /// bölümü seçilir.
    func currentDutyDateKey(now: Date = Date()) -> String {

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul") ?? .current

        let handoverHour = 8
        let hour = calendar.component(.hour, from: now)

        let target = hour < handoverHour
            ? (calendar.date(byAdding: .day, value: -1, to: now) ?? now)
            : now

        let day = calendar.component(.day, from: target)
        let month = calendar.component(.month, from: target)

        let months = [
            "", "Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran",
            "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"
        ]

        guard month >= 1, month <= 12 else { return "" }

        return normalize("\(day) \(months[month])")
    }


    /// "… 19 Ağustos Çarşamba " parçasından "19 agustos" anahtarını çıkarır.
    func periodKey(from fragment: String) -> String {

        let text = cleanHTML(fragment)
            .replacingOccurrences(of: "\n", with: " ")

        let months =
            "Ocak|Şubat|Mart|Nisan|Mayıs|Haziran|"
            + "Temmuz|Ağustos|Eylül|Ekim|Kasım|Aralık"

        let pattern = "(\\d{1,2}\\s+(?:" + months + "))[^0-9]*$"

        guard let match = firstMatch(pattern, in: text) else {
            return ""
        }

        return normalize(match)
    }


    /// Başlık bulunamazsa: içinde gerçekten veri satırı olan ilk tablo.
    func firstTableWithRows(in html: String) -> String? {

        let starts = ranges(of: #"(?is)<table\b"#, in: html)

        for (index, start) in starts.enumerated() {

            let end = index + 1 < starts.count
                ? starts[index + 1].lowerBound
                : html.endIndex

            let chunk = String(html[start.lowerBound..<end])

            if !parseTableRows(from: chunk, fallbackDistrict: nil).isEmpty {
                return chunk
            }
        }

        return nil
    }


    // MARK: - Ana çıkarıcı (etiketten bağımsız)

    /// Siteler tablo, kart veya div ızgarası kullanabiliyor; HTML etiketine
    /// bağlı ayrıştırma bu yüzden kırılıyordu. Bu çıkarıcı yapıya değil METNE bakar:
    ///
    /// 1. "… Eczanesi" ile biten metin düğümlerini bulur (gerçek eczane adları hep böyledir).
    /// 2. Her adın ARDINDAN gelen ~1800 karakterlik pencerede adres, telefon ve
    ///    koordinatı arar. Pencere, o kaydın kendi bloğuna denk gelir.
    ///
    /// Böylece tablo da olsa kart da olsa aynı sonucu verir.
    func extractPharmacies(
        from html: String,
        fallbackDistrict: String?
    ) -> [Pharmacy] {

        guard let regex = try? NSRegularExpression(
            pattern: #">\s*([^<>{}]{2,60}?[EeİiIı]czanesi)\s*<"#
        ) else {
            return []
        }

        var result: [Pharmacy] = []
        var seen = Set<String>()

        let fullRange = NSRange(html.startIndex..., in: html)

        for match in regex.matches(in: html, range: fullRange) {

            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: html),
                  let matchRange = Range(match.range, in: html)
            else { continue }

            let name = cleanHTML(String(html[nameRange]))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard isValidDutyPharmacyName(name) else { continue }

            let windowEnd = html.index(
                matchRange.upperBound,
                offsetBy: 1800,
                limitedBy: html.endIndex
            ) ?? html.endIndex

            let window = String(html[matchRange.upperBound..<windowEnd])

            let address = addressInWindow(window, name: name)
            let phone = extractPhone(window)
            let coordinates = extractCoordinates(window)

            // Menü/başlık kırıntısı ele: adres veya telefon mutlaka olmalı.
            guard !address.isEmpty || phone != nil else { continue }

            let district =
                extractDistrict(window, text: cleanHTML(window))
                ?? fallbackDistrict

            let key = normalize(name) + "|" + String(normalize(address).prefix(25))

            guard seen.insert(key).inserted else { continue }

            result.append(
                Pharmacy(
                    name: name,
                    address: address,
                    phone: phone,
                    latitude: coordinates?.0,
                    longitude: coordinates?.1,
                    district: district
                )
            )
        }

        return result
    }


    /// Penceredeki ilk ADRES gibi görünen metin düğümü.
    func addressInWindow(_ window: String, name: String) -> String {

        let normalizedName = normalize(name)

        for node in regexMatches(#">([^<>]{12,200})<"#, in: window) {

            let text = cleanHTML(node)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard text.count >= 15,
                  normalize(text) != normalizedName,
                  looksLikeAddress(text)
            else { continue }

            return cleanAddress(text)
        }

        let flat = cleanHTML(window)
            .replacingOccurrences(of: "\n", with: " ")

        if looksLikeAddress(flat) {
            return cleanAddress(String(flat.prefix(160)))
        }

        return ""
    }


    /// Türkçe adres kelimeleri: Mah., Cad., Sok., No: …
    func looksLikeAddress(_ text: String) -> Bool {

        let tokens = Set(
            normalize(text)
                .split(separator: " ")
                .map(String.init)
        )

        let keys: Set<String> = [
            "mah", "mahalle", "mahallesi", "mh",
            "cad", "cd", "cadde", "caddesi",
            "sok", "sk", "sokak", "sokagi",
            "bulvar", "bulvari", "blv", "bul",
            "no", "kume", "mevki", "mevkii", "sitesi", "apt"
        ]

        return !tokens.isDisjoint(with: keys)
    }


    // MARK: - Tablo tabanlı parser (birincil)

    func parseTableRows(
        from html: String,
        fallbackDistrict: String?
    ) -> [Pharmacy] {

        let rows = regexMatches(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, in: html)

        var result: [Pharmacy] = []

        for row in rows {

            let cells = regexMatches(#"(?is)<t[dh]\b[^>]*>(.*?)</t[dh]>"#, in: row)
                .map { cleanHTML($0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard cells.count >= 2 else { continue }

            let rawName = cells[0]

            guard isPossiblePharmacyName(rawName) else { continue }

            let name = cleanPharmacyName(rawName)

            guard isValidDutyPharmacyName(name) else { continue }

            var address = cells.count > 1 ? cleanAddress(cells[1]) : ""
            if address.isEmpty, cells.count > 2 {
                address = cleanAddress(cells[2])
            }

            let phone = extractPhone(row)

            let district =
                extractDistrict(row, text: cells.joined(separator: "\n"))
                ?? fallbackDistrict

            let coordinates = extractCoordinates(row)

            // Menü/başlık kırıntılarını ele: adres veya telefon mutlaka olmalı.
            guard !address.isEmpty || phone != nil else { continue }

            result.append(
                Pharmacy(
                    name: name,
                    address: address,
                    phone: phone,
                    latitude: coordinates?.0,
                    longitude: coordinates?.1,
                    district: district
                )
            )
        }

        return result
    }


    // MARK: - Yedek parser (tablo bulunamazsa)

    func parseGenericBlocks(
        from html: String,
        fallbackDistrict: String?
    ) -> [Pharmacy] {

        let blockPatterns = [
            #"(?is)<div[^>]*class=["'][^"']*(?:eczane|pharmacy|card)[^"']*["'][^>]*>.*?</div>"#,
            #"(?is)<article\b[^>]*>.*?</article>"#,
            #"(?is)<li\b[^>]*>.*?eczane.*?</li>"#
        ]

        var blocks: [String] = []

        for pattern in blockPatterns {
            blocks.append(contentsOf: regexMatches(pattern, in: html))
        }

        var result: [Pharmacy] = []

        for rawBlock in blocks {

            let text = cleanHTML(rawBlock)

            guard normalize(text).contains("eczane") else { continue }

            guard let rawName = extractName(rawBlock, text: text) else { continue }

            let name = cleanPharmacyName(rawName)

            guard isValidDutyPharmacyName(name) else { continue }

            result.append(
                Pharmacy(
                    name: name,
                    address: cleanAddress(
                        extractAddress(rawBlock, text: text, name: name)
                    ),
                    phone: extractPhone(rawBlock),
                    latitude: extractCoordinates(rawBlock)?.0,
                    longitude: extractCoordinates(rawBlock)?.1,
                    district: extractDistrict(rawBlock, text: text) ?? fallbackDistrict
                )
            )
        }

        return result
    }


    func extractName(_ raw: String, text: String) -> String? {

        let patterns = [
            #"(?is)<h1[^>]*>(.*?)</h1>"#,
            #"(?is)<h2[^>]*>(.*?)</h2>"#,
            #"(?is)<h3[^>]*>(.*?)</h3>"#,
            #"(?is)<h4[^>]*>(.*?)</h4>"#,
            #"(?is)<a[^>]*>(.*?eczanesi.*?)</a>"#,
            #"(?is)<strong[^>]*>(.*?)</strong>"#,
            #"(?is)<b[^>]*>(.*?)</b>"#
        ]

        for pattern in patterns {
            if let match = firstMatch(pattern, in: raw) {
                let value = cleanHTML(match)
                if isPossiblePharmacyName(value) {
                    return value
                }
            }
        }

        for line in text.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }) {

            if isPossiblePharmacyName(line) {
                return line
            }
        }

        return nil
    }


    func extractAddress(
        _ raw: String,
        text: String,
        name: String
    ) -> String {

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let normalizedName = normalize(name)

        for line in lines {

            let normalizedLine = normalize(line)

            if normalizedLine == normalizedName { continue }
            if normalizedLine.count < 12 { continue }
            if normalizedLine.contains("telefon") { continue }
            if normalizedLine.contains("yol tarifi") { continue }

            return line
        }

        return lines.dropFirst().first ?? ""
    }


    func cleanAddress(_ value: String) -> String {

        var text = value

        for junk in [
            "Yol Tarifi", "Haritada Göster", "Haritada Gör",
            "Telefon", "Ara", "Detay"
        ] {
            text = text.replacingOccurrences(
                of: junk,
                with: " ",
                options: .caseInsensitive
            )
        }

        text = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    /// Gerçek bir nöbetçi eczane kaydı mı?
    /// Türkiye'de eczane adları "… Eczanesi" ile biter; menü, bağlantı ve
    /// reklam metinleri bu testi geçemez.
    func isValidDutyPharmacyName(_ name: String) -> Bool {

        let normalized = normalize(name)

        guard normalized.count >= 5, normalized.count <= 60 else {
            return false
        }

        // Türkiye'de eczane adları İSTİSNASIZ "… Eczanesi" ile biter.
        // "24 Saat Açık Eczane", "En Yakın Eczane", "Gece Açık Eczane" gibi
        // SSS/footer başlıkları "eczane" ile biter, "eczanesi" ile değil.
        guard normalized.hasSuffix("eczanesi") else {
            return false
        }

        // Gerçek ad en az iki kelimedir ("Hayat Eczanesi").
        guard normalized.contains(" "), !normalized.hasPrefix("eczane") else {
            return false
        }

        // Site içi tanıtım/SSS kalıpları.
        let banned = [
            "24 saat", "gece acik", "pazar gunu", "en yakin",
            "acik eczanesi", "sik sorulan", "yayin kunyesi", "hakkinda"
        ]

        for item in banned where normalized.contains(item) {
            return false
        }

        let blocked = ["nobetci", "listele", "haritada", "tum eczane", "eczane ara"]

        for item in blocked where normalized.contains(item) {
            return false
        }

        return true
    }


    func isPossiblePharmacyName(_ value: String) -> Bool {

        let normalizedValue = normalize(value)

        guard normalizedValue.contains("eczane")
                || normalizedValue.contains("ecz ")
        else { return false }

        let blocked = [
            "nobetci eczaneler",
            "eczaneleri listele",
            "eczane ara",
            "tum eczaneler",
            "eczane bul"
        ]

        for item in blocked where normalizedValue.contains(item) {
            return false
        }

        if normalizedValue == "eczaneler" { return false }
        if normalizedValue == "eczane" { return false }

        return true
    }


    func cleanPharmacyName(_ value: String) -> String {

        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    func extractPhone(_ raw: String) -> String? {

        let patterns = [
            #"(0\s*\(?\d{3}\)?[\s\-\.]?\d{3}[\s\-\.]?\d{2}[\s\-\.]?\d{2})"#,
            #"(\+90[\s\-\.]?\(?\d{3}\)?[\s\-\.]?\d{3}[\s\-\.]?\d{2}[\s\-\.]?\d{2})"#,
            #"(?i)tel:\s*([+0-9\s\(\)\-]{10,20})"#
        ]

        for pattern in patterns {
            if let match = firstMatch(pattern, in: raw) {
                let value = cleanHTML(match)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value.filter({ $0.isNumber }).count >= 10 {
                    return value
                }
            }
        }

        return nil
    }


    func extractDistrict(_ raw: String, text: String) -> String? {

        if let match = firstMatch(
            #"(?is)<a[^>]+href=["'][^"']*nobetci-[a-z0-9\-]+-([a-z0-9\-]+)["']"#,
            in: raw
        ) {
            let value = match.replacingOccurrences(of: "-", with: " ")
            if value.count >= 3 { return value.capitalized }
        }

        if let match = firstMatch(
            #"(?i)(?:İlçe|Ilce)\s*[:\-]\s*([^\n<]{3,40})"#,
            in: text
        ) {
            return match.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }


    func extractCoordinates(_ text: String) -> (Double, Double)? {

        let patterns = [
            #"(?i)(?:q=|query=|destination=|daddr=|ll=|center=)(-?\d{1,2}\.\d+),\s*(-?\d{1,3}\.\d+)"#,
            #"(?i)/@(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)"#,
            #"(?i)data-lat=["'](-?\d{1,2}\.\d+)["'][^>]*data-l(?:ng|on)=["'](-?\d{1,3}\.\d+)["']"#,
            #"(?i)(?:lat|latitude)["'=:\s]+(-?\d{1,2}\.\d+).{0,80}?(?:lng|lon|longitude)["'=:\s]+(-?\d{1,3}\.\d+)"#
        ]

        for pattern in patterns {
            if let groups = captureGroups(pattern, in: text),
               groups.count >= 3,
               let lat = Double(groups[1]),
               let lon = Double(groups[2]),
               isTurkeyCoordinate(latitude: lat, longitude: lon) {
                return (lat, lon)
            }
        }

        return nil
    }


    func isTurkeyCoordinate(latitude: Double, longitude: Double) -> Bool {
        (35.5...42.5).contains(latitude) && (25.5...45.0).contains(longitude)
    }


    // MARK: - District filter

    func filter(
        _ pharmacies: [Pharmacy],
        byDistrict district: String?
    ) -> [Pharmacy] {

        guard let district,
              !district.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return pharmacies }

        let needle = normalize(district)

        guard !needle.isEmpty else { return pharmacies }

        return pharmacies.filter { pharmacy in

            let pharmacyDistrict = normalize(pharmacy.district ?? "")
            let address = normalize(pharmacy.address)

            if !pharmacyDistrict.isEmpty {
                if pharmacyDistrict.contains(needle) { return true }
                if needle.contains(pharmacyDistrict) { return true }
            }

            return address.contains(needle)
        }
    }


    // MARK: - Location

    func reverseGeocode(_ location: CLLocation) async throws -> CLPlacemark {

        let geocoder = CLGeocoder()

        let marks = try await geocoder.reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "tr_TR")
        )

        guard let mark = marks.first else {
            throw ServiceError.cityNotFound
        }

        return mark
    }


    func detectCity(from placemark: CLPlacemark) -> String? {

        if let value = placemark.administrativeArea,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanLocationName(value)
        }

        if let value = placemark.locality,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanLocationName(value)
        }

        return nil
    }


    func detectDistrict(from placemark: CLPlacemark) -> String? {

        let city = detectCity(from: placemark)

        let candidates: [String?] = [
            placemark.subAdministrativeArea,
            placemark.locality,
            placemark.subLocality
        ]

        for candidate in candidates {

            guard let value = candidate else { continue }

            let cleaned = cleanLocationName(value)

            guard !cleaned.isEmpty else { continue }

            if let city, normalize(cleaned) == normalize(city) { continue }

            return cleaned
        }

        return nil
    }


    func cleanLocationName(_ value: String) -> String {

        value
            .replacingOccurrences(of: " İli", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " İlçesi", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    // MARK: - Coordinate enrichment

    func enrichMissingCoordinates(
        _ pharmacies: [Pharmacy],
        city: String
    ) async -> [Pharmacy] {

        // CLGeocoder hız sınırlıdır. En fazla 20 kayıt için deneriz,
        // aksi halde uygulama dakikalarca "yükleniyor" durumunda kalır.
        let limit = 20

        var result: [Pharmacy] = []
        var geocoded = 0

        for pharmacy in pharmacies {

            guard pharmacy.latitude == nil || pharmacy.longitude == nil else {
                result.append(pharmacy)
                continue
            }

            guard geocoded < limit,
                  !pharmacy.address.isEmpty else {
                result.append(pharmacy)
                continue
            }

            geocoded += 1

            let query = [pharmacy.address, pharmacy.district, city, "Türkiye"]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")

            do {
                let marks = try await CLGeocoder().geocodeAddressString(query)

                if let coordinate = marks.first?.location?.coordinate,
                   isTurkeyCoordinate(
                       latitude: coordinate.latitude,
                       longitude: coordinate.longitude
                   ) {

                    result.append(
                        Pharmacy(
                            name: pharmacy.name,
                            address: pharmacy.address,
                            phone: pharmacy.phone,
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude,
                            district: pharmacy.district,
                            sources: pharmacy.sources
                        )
                    )
                } else {
                    result.append(pharmacy)
                }

            } catch {
                result.append(pharmacy)
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return result
    }


    // MARK: - Sorting / dedupe

    func sort(
        _ pharmacies: [Pharmacy],
        around location: CLLocation
    ) -> [Pharmacy] {

        pharmacies.sorted { lhs, rhs in
            let left = lhs.distance(from: location) ?? .greatestFiniteMagnitude
            let right = rhs.distance(from: location) ?? .greatestFiniteMagnitude
            return left < right
        }
    }


    func removeDuplicates(_ pharmacies: [Pharmacy]) -> [Pharmacy] {

        var seen = Set<String>()

        return pharmacies.filter {
            seen.insert(normalize($0.name + "|" + $0.address)).inserted
        }
    }


    // MARK: - Slug / normalize

    func slug(_ value: String) -> String {

        var output = turkishLowercased(value)

        output = output.folding(
            options: .diacriticInsensitive,
            locale: Locale(identifier: "tr_TR")
        )

        output = output.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        )

        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }


    func normalize(_ value: String) -> String {

        var output = turkishLowercased(value)

        output = output.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "tr_TR")
        )

        output = output.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: " ",
            options: .regularExpression
        )

        output = output.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    func turkishLowercased(_ value: String) -> String {

        var output = value.lowercased(with: Locale(identifier: "tr_TR"))

        let replacements: [(String, String)] = [
            ("i\u{0307}", "i"),   // "İ" küçüldüğünde oluşan i + birleşik nokta
            ("ı", "i"),
            ("ç", "c"),
            ("ğ", "g"),
            ("ö", "o"),
            ("ş", "s"),
            ("ü", "u"),
            ("â", "a"),
            ("î", "i"),
            ("û", "u")
        ]

        for (source, target) in replacements {
            output = output.replacingOccurrences(of: source, with: target)
        }

        return output
    }


    // MARK: - HTML helpers

    func cleanHTML(_ input: String) -> String {

        var text = input

        text = text.replacingOccurrences(
            of: #"(?is)<script\b.*?</script>"#,
            with: "", options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"(?is)<style\b.*?</style>"#,
            with: "", options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"(?i)<br\s*/?>"#,
            with: "\n", options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"(?i)</(?:div|p|li|tr|td|h1|h2|h3|h4)>"#,
            with: "\n", options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ", options: .regularExpression
        )

        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"),
            ("&gt;", ">"), ("&#x27;", "'"), ("&uuml;", "ü"),
            ("&ouml;", "ö"), ("&ccedil;", "ç")
        ]

        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        return text
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                  .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }


    // MARK: - Regex helpers

    func regexMatches(_ pattern: String, in text: String) -> [String] {

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)

        return regex.matches(in: text, range: range).compactMap { match in
            let target = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard let swiftRange = Range(target, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }


    func firstMatch(_ pattern: String, in text: String) -> String? {

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              )
        else { return nil }

        let target = match.numberOfRanges > 1 ? match.range(at: 1) : match.range

        guard let swiftRange = Range(target, in: text) else { return nil }

        return String(text[swiftRange])
    }


    func captureGroups(_ pattern: String, in text: String) -> [String]? {

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              )
        else { return nil }

        var groups: [String] = []

        for index in 0..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                groups.append(String(text[range]))
            } else {
                groups.append("")
            }
        }

        return groups
    }


    func ranges(of pattern: String, in text: String) -> [Range<String.Index>] {

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return regex
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }


    func log(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }
}


// MARK: - Manuel arama (konum olmadan, Türkiye geneli)

extension DutyPharmacyService {

    /// Seçilen ilin ilçe listesi. Uygulamaya gömülü liste yoktur;
    /// il sayfasındaki `/nobetci-<il>-<ilce>` bağlantıları canlı okunur,
    /// böylece ilçe adları/slug'ları sitede değişse bile güncel kalır.
    func fetchDistricts(citySlug: String) async throws -> [District] {

        var lastError: ServiceError = .sourceUnavailable(detail: "bilinmiyor")

        for url in hostURLs(path: "nobetci-\(citySlug)") {

            do {
                let html = try await fetchHTML(from: url)

                let districts = parseDistricts(from: html, citySlug: citySlug)

                if !districts.isEmpty {
                    return districts
                }

                lastError = .districtsNotFound

            } catch let error as ServiceError {
                lastError = error
            }
        }

        throw lastError
    }


    /// Konum kullanmadan, doğrudan il (ve varsa ilçe) slug'ı ile
    /// BUGÜNKÜ nöbetçi eczaneleri TÜM kaynaklardan getirir.
    func fetchDuty(
        citySlug: String,
        districtSlug: String?,
        districtName: String?
    ) async throws -> [Pharmacy] {

        let result = await fetchCrossChecked(
            citySlug: citySlug,
            districtSlug: districtSlug,
            districtName: districtName
        )

        guard !result.isEmpty else {
            throw ServiceError.sourceUnavailable(
                detail: result.failures.isEmpty
                    ? "tüm kaynaklar boş döndü"
                    : result.failures.joined(separator: " | ")
            )
        }

        // Bazı kaynaklar ilçe sayfası sunmadığı için il listesi döner;
        // ilçe istendiyse burada süzülür.
        if let districtName,
           !districtName.isEmpty {

            let narrowed = filter(result.pharmacies, byDistrict: districtName)

            if !narrowed.isEmpty {
                return narrowed
            }
        }

        return result.pharmacies
    }


    func parseDistricts(
        from html: String,
        citySlug: String
    ) -> [District] {

        let pattern =
            "(?is)<a[^>]+href=[\"'][^\"']*?/nobetci-"
            + citySlug
            + "-([a-z0-9\\-]+)[\"'][^>]*>(.*?)</a>"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        var seen = Set<String>()
        var result: [District] = []

        let range = NSRange(html.startIndex..., in: html)

        for match in regex.matches(in: html, range: range) {

            guard match.numberOfRanges >= 3,
                  let slugRange = Range(match.range(at: 1), in: html)
            else { continue }

            let slug = String(html[slugRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-/"))

            guard slug.count >= 2, seen.insert(slug).inserted else { continue }

            var name = ""

            if let textRange = Range(match.range(at: 2), in: html) {
                name = cleanHTML(String(html[textRange]))
                    .replacingOccurrences(of: "\n", with: " ")
            }

            for junk in [
                "Nöbetçi Eczaneleri", "Nöbetçi Eczaneler",
                "Nöbetçi Eczane", "Nöbetçi", "Eczaneleri", "Eczaneler"
            ] {
                name = name.replacingOccurrences(
                    of: junk,
                    with: " ",
                    options: .caseInsensitive
                )
            }

            name = name
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if name.count < 2 {
                name = slug
                    .split(separator: "-")
                    .map { $0.capitalized }
                    .joined(separator: " ")
            }

            result.append(District(name: name, slug: slug))
        }

        let collation = Locale(identifier: "tr_TR")

        return result.sorted {
            $0.name.compare($1.name, options: [.caseInsensitive], range: nil, locale: collation)
                == .orderedAscending
        }
    }


    func hostURLs(path: String) -> [URL] {

        [
            "https://www.eczaneler.gen.tr/\(path)",
            "https://eczaneler.gen.tr/\(path)"
        ]
        .compactMap { URL(string: $0) }
    }
}


// MARK: - Errors

enum ServiceError: LocalizedError {

    case cityNotFound
    case invalidURL
    case sourceUnavailable(detail: String)
    case invalidResponse
    case noDutyPharmacyFound
    case districtsNotFound

    var diagnosticText: String {
        switch self {
        case .cityNotFound:         return "şehir belirlenemedi"
        case .invalidURL:           return "geçersiz adres"
        case .sourceUnavailable(let detail): return detail
        case .invalidResponse:      return "yanıt okunamadı"
        case .noDutyPharmacyFound:  return "listede kayıt yok"
        case .districtsNotFound:    return "ilçe listesi okunamadı"
        }
    }

    var errorDescription: String? {

        switch self {

        case .cityNotFound:
            return "Bulunduğun şehir belirlenemedi. Konum servislerinin açık olduğundan emin ol."

        case .invalidURL:
            return "Nöbetçi eczane adresi oluşturulamadı."

        case .sourceUnavailable(let detail):
            return """
            Nöbetçi eczane bilgisine şu anda ulaşılamıyor.

            İnternet bağlantını kontrol edip tekrar dene.
            Teknik detay: \(detail)
            """

        case .invalidResponse:
            return "Nöbetçi eczane verisi okunamadı. Kaynak sayfa beklenmedik bir biçimde döndü."

        case .noDutyPharmacyFound:
            return "Bu bölgede bugün için yayınlanmış nöbetçi eczane bulunamadı."

        case .districtsNotFound:
            return "İlçe listesi alınamadı. İnternet bağlantını kontrol edip tekrar dene."
        }
    }
}
