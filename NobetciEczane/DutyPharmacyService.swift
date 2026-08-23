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

    /// Tek paylaşılan örnek. SwiftUI görünümleri her yeniden çizimde yeniden
    /// kurulduğu için her seferinde yeni bir URLSession açılıyordu.
    static let shared = DutyPharmacyService()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral

        // Hız hedefi: sonuç en geç 10-15 saniyede. Yavaş bir site tüm aramayı
        // sürüklemesin diye istek başına 8 sn üst sınır.
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false          // Ağ yoksa beklemek yerine hemen hata ver.

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
    /// 2. Konumdan İL ve İLÇE belirlenir.
    /// 3. O günün nöbetçi listesi TÜM KAYNAKLARDAN paralel çekilip çapraz doğrulanır.
    /// 4. Nöbeti BİTMİŞ (artık kapalı) kayıtlar elenir.
    /// 5. Liste, telefona en yakın eczaneden en uzağa sıralanır.
    func fetchNearest(
        to location: CLLocation,
        limit: Int = 15,
        maxDistance: CLLocationDistance = 20_000,
        knownPlace: (city: String, district: String?)? = nil
    ) async throws -> [Pharmacy] {

        // Konum zaten çözülmüşse (arayüz açılışta çözüyor) yeniden çözme:
        // her reverse-geocode 0,5-1 sn kazandırır.
        let city: String
        let district: String?

        if let knownPlace {
            city = knownPlace.city
            district = knownPlace.district
        } else {
            let placemark = try await reverseGeocode(location)

            guard let detected = detectCity(from: placemark),
                  !detected.isEmpty else {
                throw ServiceError.cityNotFound
            }

            city = detected
            district = detectDistrict(from: placemark)
        }

        let citySlug = slug(city)

        log("📍 Şehir: \(city) (\(citySlug)) / İlçe: \(district ?? "-")")

        // İLÇE (en isabetli liste) ve İL GENELİ (komşu bölgeler) taramaları
        // AYNI ANDA başlar; toplam süre yavaş olanın süresi kadar olur.
        async let districtTask: CrossCheckResult? = {
            guard let district, !district.isEmpty else { return nil }
            return await self.fetchCrossChecked(
                citySlug: citySlug,
                districtSlug: self.slug(district),
                districtName: district
            )
        }()

        async let cityTask = fetchCrossChecked(
            citySlug: citySlug,
            districtSlug: nil,
            districtName: nil
        )

        var result = await districtTask ?? CrossCheckResult()
        let cityWide = await cityTask

        if result.isEmpty {
            result = cityWide
        } else if !cityWide.isEmpty {

            // İl listesi, ilçe listesine ancak GÜN GÜVENCESİ ilçe listesinden
            // düşük DEĞİLSE yeni kayıt ekleyebilir. Aksi hâlde (ör. ilçe listesi
            // dönem başlığıyla kanıtlı ama il listesi bayat bir siteden geldiyse)
            // yalnızca eksik telefon/koordinat tamamlar — Saydam vakası böyle
            // kapatıldı: bayat il listesi kanıtlı ilçe listesine kayıt sızdıramaz.
            let canAppend = cityWide.dayConfidence >= result.dayConfidence

            result.pharmacies = merge(
                result.pharmacies,
                with: cityWide.pharmacies,
                appendUnmatched: canAppend
            )

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

        // Nöbeti sona ermiş kayıt listeye ASLA girmez.
        let active = result.pharmacies.filter {
            PharmacyHours.isDutyStillActive(endsAt: $0.dutyEndsAt)
        }

        guard !active.isEmpty else {
            throw ServiceError.dutyListNotPublished
        }

        // KESİN KURAL: EN AZ İKİ bağımsız kaynağın doğrulamadığı kayıt gösterilmez.
        // Tek kaynağın söylediği eczane, o kaynak yanılıyorsa kullanıcıyı kapalı
        // kapıya gönderir; iki kaynak aynı anda nadiren yanılır.
        let confirmed = active.filter { $0.isCrossVerified }

        guard !confirmed.isEmpty else {
            throw ServiceError.notCrossVerified(
                sourceCount: result.succeeded.count
            )
        }

        log("✅ Kaynaklar: \(result.succeeded.joined(separator: ", ")) — \(confirmed.count)/\(active.count) kayıt çapraz doğrulandı")

        // Koordinatı hiçbir kaynaktan çıkmayan kayıtlar adresten tamamlanır.
        let enriched = await enrichMissingCoordinates(confirmed, city: city)

        // 20 km'den uzak eczane gösterilmez. Koordinatı çözülemeyen kayıt
        // (mesafesi bilinmiyor) elenmez; sıralamada en sona düşer.
        let inRange = enriched.filter { pharmacy in
            guard let distance = pharmacy.distance(from: location) else { return true }
            return distance <= maxDistance
        }

        guard !inRange.isEmpty else {
            throw ServiceError.noDutyPharmacyFound
        }

        // En yakından en uzağa; en fazla `limit` kayıt.
        return Array(sort(inRange, around: location).prefix(limit))
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


    func fetchHTML(from url: URL) async throws -> String {

        var lastDetail = "bilinmiyor"

        // TEK deneme: 15 kaynak paralel sorgulandığı için tek tek yeniden
        // denemek yerine diğer kaynaklara güvenmek çok daha hızlıdır.
        for attempt in 1...1 {

            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 8
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

            _ = attempt
        }

        throw ServiceError.sourceUnavailable(detail: lastDetail)
    }


    // MARK: - Bugünkü nöbet dönemi

    /// Sayfada birden çok güne ait nöbet listesi bulunur. Dönemler şu başlıklarla ayrılır:
    ///
    ///   "22 Ağustos C.tesi gününden 23 Ağustos Pazar sabahına kadar"
    ///   "23 Ağustos Pazar gün boyu ve 24 Ağustos P.tesi sabahına kadar"
    ///   "24 Ağustos P.tesi akşamından 25 Ağustos Salı sabahına kadar"
    ///
    /// ESKİ HATA: bölüm sınırı olarak yalnızca "akşam" kelimesi aranıyordu.
    /// Cumartesi ("gününden") ve pazar ("gün boyu") başlıklarında bu kelime GEÇMEZ;
    /// bu yüzden doğru bölüm bulunamıyor ve liste yanlış güne — çoğu zaman ERTESİ güne —
    /// kayıyordu. Uygulamanın "nöbetçi olmayan / kapalı eczane gösterme" sorununun
    /// asıl kaynağı buydu.
    ///
    /// YENİ KURAL: başlığın BAŞLANGIÇ tarihi okunur ve cihaz saatiyle (Türkiye saati,
    /// sabah 09:00 devri) hesaplanan bugünün nöbet tarihine eşleşen bölüm alınır.
    /// Eşleşme yoksa bölüm DÖNMEZ — yanlış günün listesini göstermektense hiç
    /// göstermemek doğrudur; diğer kaynaklar devreye girer.

    struct DutySectionMatch {
        let html: String
        let dutyDate: Date
        let endsAt: Date?

        /// Bölüm, sayfadaki BUGÜNE ait dönem başlığıyla eşleşerek mi bulundu?
        /// `false` ise sayfada dönem başlığı yoktur; günün doğruluğu ayrıca
        /// (sayfada bugünün tarihi geçiyor mu diye) sınanmalıdır.
        let matchedPeriod: Bool
    }

    /// Sayfadaki nöbet dönemi başlıklarının anahtarı ve konumu.
    struct DutyPeriodMarker {
        let key: String            // "23 agustos"
        let start: String.Index
    }


    func dutyPeriodMarkers(in html: String) -> [DutyPeriodMarker] {

        let months =
            "Ocak|Şubat|Mart|Nisan|Mayıs|Haziran|"
            + "Temmuz|Ağustos|Eylül|Ekim|Kasım|Aralık"

        // Bir DÖNEM BAŞLANGICI: tarih + (gün adı) + dönem kelimesi.
        // Dönem SONU ("… sabahına kadar") bilerek eşleşmez; yoksa bölüm sınırı
        // bir gün ileri kayardı.
        let pattern =
            "(?i)(\\d{1,2})\\s*(?:&nbsp;|\\s)*(" + months + ")"
            + "(?:\\s*\\d{4})?"
            + "[^0-9<>]{0,24}?"
            + "(gününden|akşamından|gecesinden|gün boyu|gün boyunca|günü boyunca)"

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var markers: [DutyPeriodMarker] = []

        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {

            guard match.numberOfRanges >= 3,
                  let full = Range(match.range, in: html),
                  let dayRange = Range(match.range(at: 1), in: html),
                  let monthRange = Range(match.range(at: 2), in: html)
            else { continue }

            // "03 Eylül" ile "3 Eylül" aynı gündür: baştaki sıfır atılır.
            let day = Int(html[dayRange]) ?? -1
            let key = normalize("\(day) \(html[monthRange])")

            guard !key.isEmpty else { continue }

            // Aynı dönem başlığı sayfada birden çok kez geçebilir;
            // yalnızca anahtarın DEĞİŞTİĞİ yerler yeni bölüm sınırıdır.
            if let last = markers.last, last.key == key { continue }

            markers.append(DutyPeriodMarker(key: key, start: full.lowerBound))
        }

        return markers
    }


    /// Bugünün nöbet dönemine ait HTML bölümü.
    /// Sayfa dönem başlığı kullanıyor ama BUGÜNÜ yayınlamıyorsa `nil` döner.
    func todayDutySection(from html: String, now: Date = Date()) -> DutySectionMatch? {

        let dutyDate = PharmacyHours.currentDutyDate(now)
        let targetKey = dutyDateKey(for: dutyDate)
        let endsAt = PharmacyHours.dutyEnd(forDutyDate: dutyDate)

        let markers = dutyPeriodMarkers(in: html)

        guard !markers.isEmpty else {

            // Sayfada dönem başlığı yok. Bu sayfalar genelde yalnızca bugünü
            // yayınlar; yine de `matchedPeriod = false` ile işaretlenir ve
            // çağıran taraf günü sayfadaki tarihten doğrular.
            return DutySectionMatch(
                html: firstTableWithRows(in: html) ?? html,
                dutyDate: dutyDate,
                endsAt: endsAt,
                matchedPeriod: false
            )
        }

        // Aynı başlık sayfa başlığında / meta alanında da geçebildiği için
        // hedef anahtarla eşleşen TÜM adaylar denenir; içinde gerçekten
        // eczane kaydı olan ilk bölüm alınır.
        let candidates = markers.indices.filter { markers[$0].key == targetKey }

        guard !candidates.isEmpty else {
            log("🚫 Bugünün dönemi (\(targetKey)) sayfada yok: \(markers.map(\.key))")
            return nil
        }

        var firstBody: String?

        for index in candidates {

            let start = markers[index].start
            let end = index + 1 < markers.count ? markers[index + 1].start : html.endIndex

            let body = trimFooter(String(html[start..<end]))

            if firstBody == nil { firstBody = body }

            if !extractPharmacies(from: body, fallbackDistrict: nil).isEmpty {
                return DutySectionMatch(
                    html: body,
                    dutyDate: dutyDate,
                    endsAt: endsAt,
                    matchedPeriod: true
                )
            }
        }

        return DutySectionMatch(
            html: firstBody ?? html,
            dutyDate: dutyDate,
            endsAt: endsAt,
            matchedPeriod: true
        )
    }


    /// Sayfa BUGÜNÜN tarihini yazıyor mu?
    /// Dönem başlığı olmayan kaynaklarda günün doğruluğu böyle sınanır;
    /// tarihi yazmayan bir kaynak listeyi TEK BAŞINA kuramaz.
    func pageMentionsToday(_ html: String, now: Date = Date()) -> Bool {

        let calendar = PharmacyHours.calendar
        let dutyDate = PharmacyHours.currentDutyDate(now)

        let day = calendar.component(.day, from: dutyDate)
        let month = calendar.component(.month, from: dutyDate)
        let year = calendar.component(.year, from: dutyDate)

        // Haber portallarında (milliyet, sabah) liste sayfanın derinlerinde
        // olabildiği için geniş bir pencere taranır.
        let text = normalize(String(html.prefix(300_000)))

        var needles = [dutyDateKey(for: dutyDate)]                    // "23 agustos"

        needles.append("\(day) \(month) \(year)")                   // 23.08.2026
        needles.append(String(format: "%02d %02d %d", day, month, year))
        needles.append("\(year) \(month) \(day)")                   // 2026-08-23
        needles.append(String(format: "%d %02d %02d", year, month, day))

        return needles.contains { !$0.isEmpty && text.contains($0) }
    }


    /// Son dönemin gövdesi sayfa sonuna kadar uzanır; altbilgideki
    /// "24 Saat Açık Eczane", "Sık Sorulan Sorular" gibi başlıklar listeye
    /// sızmasın diye altbilgi kesilir.
    func trimFooter(_ section: String) -> String {

        let markers = [
            #"(?is)<footer\b"#,
            #"(?i)Sık Sorulan"#,
            #"(?i)Yayın Künyesi"#
        ]

        // Kesme noktası bölümün en az 200 karakter içinde olmalı; başlığın hemen
        // altındaki bir bağlantı yüzünden tüm bölüm silinmesin.
        guard let minimum = section.index(
            section.startIndex,
            offsetBy: 200,
            limitedBy: section.endIndex
        ) else {
            return section
        }

        var cut = section.endIndex

        for pattern in markers {
            for range in ranges(of: pattern, in: section)
            where range.lowerBound >= minimum && range.lowerBound < cut {
                cut = range.lowerBound
                break
            }
        }

        return String(section[section.startIndex..<cut])
    }


    /// "23 agustos" biçiminde dönem anahtarı.
    func dutyDateKey(for date: Date) -> String {

        let calendar = PharmacyHours.calendar

        let day = calendar.component(.day, from: date)
        let month = calendar.component(.month, from: date)

        let months = [
            "", "Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran",
            "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"
        ]

        guard month >= 1, month <= 12 else { return "" }

        return normalize("\(day) \(months[month])")
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

        // (?i): "ÖZLEM ECZANESİ" gibi tamamı büyük harf yazan kaynaklar da okunmalı.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)>\s*([^<>{}]{2,60}?[EeİiIı]czanes[iİIı])\s*<"#
        ) else {
            return []
        }

        var result: [Pharmacy] = []
        var seen = Set<String>()

        let fullRange = NSRange(html.startIndex..., in: html)

        let matches = regex.matches(in: html, range: fullRange)

        for (index, match) in matches.enumerated() {

            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: html),
                  let matchRange = Range(match.range, in: html)
            else { continue }

            let name = cleanHTML(String(html[nameRange]))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard isValidDutyPharmacyName(name) else { continue }

            // Pencere EN FAZLA bir sonraki eczane adına kadar uzanır; yoksa bir kaydın
            // adresi/telefonu komşu kayda karışıyordu (kullanıcı yanlış adrese gidiyordu).
            var windowEnd = html.index(
                matchRange.upperBound,
                offsetBy: 1800,
                limitedBy: html.endIndex
            ) ?? html.endIndex

            if index + 1 < matches.count,
               let nextStart = Range(matches[index + 1].range, in: html)?.lowerBound,
               nextStart > matchRange.upperBound,
               nextStart < windowEnd {
                windowEnd = nextStart
            }

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

        // Bağlantı, kaydın KENDİ bloğunun başında olmalı; ilerideki
        // "diğer ilçeler" menüsü kayda yanlış ilçe yazıyordu.
        if let match = firstMatch(
            #"(?is)<a[^>]+href=["'][^"']*nobetci-[a-z0-9\-]+-([a-z0-9\-]+)["']"#,
            in: String(raw.prefix(600))
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

        // CLGeocoder hız sınırlıdır ve her çağrı ~0,5 sn sürer.
        // 10-15 sn hedefi için en fazla 8 kayıt tamamlanır; koordinatı
        // çözülemeyen kayıt yine listelenir, yalnızca mesafesi bilinmez.
        let limit = 8

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
                            sources: pharmacy.sources,
                            kind: pharmacy.kind,
                            dutyEndsAt: pharmacy.dutyEndsAt,
                            closesAt: pharmacy.closesAt
                        )
                    )
                } else {
                    result.append(pharmacy)
                }

            } catch {
                result.append(pharmacy)
            }

            try? await Task.sleep(nanoseconds: 60_000_000)
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

        // Nöbeti sona ermiş (artık kapalı) kayıt listeye ASLA girmez.
        let active = result.pharmacies.filter {
            PharmacyHours.isDutyStillActive(endsAt: $0.dutyEndsAt)
        }

        guard !active.isEmpty else {
            throw ServiceError.dutyListNotPublished
        }

        // KESİN KURAL: en az iki bağımsız kaynağın doğrulamadığı kayıt gösterilmez.
        let confirmed = active.filter { $0.isCrossVerified }

        guard !confirmed.isEmpty else {
            throw ServiceError.notCrossVerified(
                sourceCount: result.succeeded.count
            )
        }

        // Bazı kaynaklar ilçe sayfası sunmadığı için il listesi döner;
        // ilçe istendiyse burada süzülür.
        if let districtName,
           !districtName.isEmpty {

            let narrowed = filter(confirmed, byDistrict: districtName)

            if !narrowed.isEmpty {
                return narrowed
            }
        }

        return confirmed
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
    case dutyListNotPublished
    case notCrossVerified(sourceCount: Int)
    case districtsNotFound

    var diagnosticText: String {
        switch self {
        case .cityNotFound:         return "şehir belirlenemedi"
        case .invalidURL:           return "geçersiz adres"
        case .sourceUnavailable(let detail): return detail
        case .invalidResponse:      return "yanıt okunamadı"
        case .noDutyPharmacyFound:  return "listede kayıt yok"
        case .dutyListNotPublished: return "bugünün nöbet listesi yayınlanmamış"
        case .notCrossVerified(let count): return "çapraz doğrulama yok (\(count) kaynak yanıt verdi)"
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

        case .dutyListNotPublished:
            return """
            Bugünün (\(Date().formatted(date: .abbreviated, time: .omitted))) nöbet listesi \
            kaynaklarda henüz yayınlanmamış görünüyor.

            Yanlış güne ait liste göstermemek için bu kayıtlar gizlendi. \
            Birazdan tekrar deneyebilir ya da 182 ALO Sağlık Hattı'nı arayabilirsin.
            """

        case .notCrossVerified(let count):
            return """
            Nöbetçi listesi yalnızca tek kaynaktan alınabildi (\(count) kaynak yanıt verdi) \
            ve ikinci bir kaynakla doğrulanamadı.

            Yanlış eczaneye gitmeni önlemek için doğrulanmamış liste gösterilmiyor. \
            Birazdan tekrar dene ya da 182 ALO Sağlık Hattı'nı arayabilirsin.
            """

        case .districtsNotFound:
            return "İlçe listesi alınamadı. İnternet bağlantını kontrol edip tekrar dene."
        }
    }
}
