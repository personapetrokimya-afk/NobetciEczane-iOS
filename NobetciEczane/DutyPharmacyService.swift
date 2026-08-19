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

    func fetchNearest(to location: CLLocation) async throws -> [Pharmacy] {

        let placemark = try await reverseGeocode(location)

        guard let city = detectCity(from: placemark),
              !city.isEmpty else {
            throw ServiceError.cityNotFound
        }

        let district = detectDistrict(from: placemark)

        log("📍 Şehir: \(city) / İlçe: \(district ?? "-")")

        var pharmacies: [Pharmacy] = []
        var lastFailure: String?

        // 1) Önce ilçe sayfası. En doğru ve en küçük liste burasıdır.
        if let district, !district.isEmpty {
            do {
                pharmacies = try await loadPharmacies(
                    city: city,
                    district: district
                )
            } catch let error as ServiceError {
                lastFailure = error.diagnosticText
                log("ℹ️ İlçe sayfası kullanılamadı: \(error.diagnosticText)")
            }
        }

        // 2) İlçe sayfası yoksa/boşsa il sayfasına düş ve ilçeye göre süz.
        if pharmacies.isEmpty {
            do {
                let cityWide = try await loadPharmacies(
                    city: city,
                    district: nil
                )

                pharmacies = filter(
                    cityWide,
                    byDistrict: district
                )

                // İlçe eşleşmesi yoksa kullanıcıyı boş bırakmak yerine
                // il genelindeki en yakın nöbetçileri göster.
                if pharmacies.isEmpty {
                    pharmacies = cityWide
                }

            } catch let error as ServiceError {
                throw ServiceError.sourceUnavailable(
                    detail: error.diagnosticText
                        + (lastFailure.map { " | İlçe: \($0)" } ?? "")
                )
            }
        }

        guard !pharmacies.isEmpty else {
            throw ServiceError.noDutyPharmacyFound
        }

        // Koordinatı olmayan kayıtları (sınırlı sayıda) adresten tamamla.
        pharmacies = await enrichMissingCoordinates(
            pharmacies,
            city: city
        )

        return sort(pharmacies, around: location)
    }


    // MARK: - Loading

    private func loadPharmacies(
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
    private func candidateURLs(
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


    private func fetchHTML(from url: URL) async throws -> String {

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

    /// Sayfada 3 güne ait nöbet listesi bulunur.
    /// Yalnızca ilk (bugünkü) listeyi almazsak yarınki eczaneleri de gösteririz.
    private func extractTodaySection(from html: String) -> String {

        let tableRanges = ranges(of: #"(?is)<table\b"#, in: html)

        guard let firstTable = tableRanges.first else {
            return html
        }

        // İlk tablodan sonra gelen ikinci tablo bir sonraki güne aittir.
        if tableRanges.count > 1 {
            let secondTable = tableRanges[1]
            return String(html[firstTable.lowerBound..<secondTable.lowerBound])
        }

        // Tek tablo varsa </table> sonuna kadar al.
        if let closing = html.range(
            of: #"(?is)</table>"#,
            options: .regularExpression,
            range: firstTable.lowerBound..<html.endIndex
        ) {
            return String(html[firstTable.lowerBound..<closing.upperBound])
        }

        return String(html[firstTable.lowerBound...])
    }


    // MARK: - Tablo tabanlı parser (birincil)

    private func parseTableRows(
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

            guard name.count >= 3, name.count <= 100 else { continue }

            var address = cells.count > 1 ? cleanAddress(cells[1]) : ""
            if address.isEmpty, cells.count > 2 {
                address = cleanAddress(cells[2])
            }

            let phone = extractPhone(row)

            let district =
                extractDistrict(row, text: cells.joined(separator: "\n"))
                ?? fallbackDistrict

            let coordinates = extractCoordinates(row)

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

    private func parseGenericBlocks(
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

            guard name.count >= 3, name.count <= 100 else { continue }

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


    private func extractName(_ raw: String, text: String) -> String? {

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


    private func extractAddress(
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


    private func cleanAddress(_ value: String) -> String {

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


    private func isPossiblePharmacyName(_ value: String) -> Bool {

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


    private func cleanPharmacyName(_ value: String) -> String {

        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func extractPhone(_ raw: String) -> String? {

        let patterns = [
            #"(?i)tel:\s*([+0-9\s\(\)\-]{10,20})"#,
            #"(0\s?\d{3}[\s\-\.]?\d{3}[\s\-\.]?\d{2}[\s\-\.]?\d{2})"#,
            #"(\+90[\s\-\.]?\d{3}[\s\-\.]?\d{3}[\s\-\.]?\d{2}[\s\-\.]?\d{2})"#
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


    private func extractDistrict(_ raw: String, text: String) -> String? {

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


    private func extractCoordinates(_ text: String) -> (Double, Double)? {

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


    private func isTurkeyCoordinate(latitude: Double, longitude: Double) -> Bool {
        (35.5...42.5).contains(latitude) && (25.5...45.0).contains(longitude)
    }


    // MARK: - District filter

    private func filter(
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

    private func reverseGeocode(_ location: CLLocation) async throws -> CLPlacemark {

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


    private func detectCity(from placemark: CLPlacemark) -> String? {

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


    private func detectDistrict(from placemark: CLPlacemark) -> String? {

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


    private func cleanLocationName(_ value: String) -> String {

        value
            .replacingOccurrences(of: " İli", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " İlçesi", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    // MARK: - Coordinate enrichment

    private func enrichMissingCoordinates(
        _ pharmacies: [Pharmacy],
        city: String
    ) async -> [Pharmacy] {

        // CLGeocoder hız sınırlıdır. En fazla 10 kayıt için deneriz,
        // aksi halde uygulama dakikalarca "yükleniyor" durumunda kalır.
        let limit = 10

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
                            district: pharmacy.district
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

    private func sort(
        _ pharmacies: [Pharmacy],
        around location: CLLocation
    ) -> [Pharmacy] {

        pharmacies.sorted { lhs, rhs in
            let left = lhs.distance(from: location) ?? .greatestFiniteMagnitude
            let right = rhs.distance(from: location) ?? .greatestFiniteMagnitude
            return left < right
        }
    }


    private func removeDuplicates(_ pharmacies: [Pharmacy]) -> [Pharmacy] {

        var seen = Set<String>()

        return pharmacies.filter {
            seen.insert(normalize($0.name + "|" + $0.address)).inserted
        }
    }


    // MARK: - Slug / normalize

    private func slug(_ value: String) -> String {

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


    private func normalize(_ value: String) -> String {

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


    private func turkishLowercased(_ value: String) -> String {

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

    private func cleanHTML(_ input: String) -> String {

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

    private func regexMatches(_ pattern: String, in text: String) -> [String] {

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


    private func firstMatch(_ pattern: String, in text: String) -> String? {

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


    private func captureGroups(_ pattern: String, in text: String) -> [String]? {

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


    private func ranges(of pattern: String, in text: String) -> [Range<String.Index>] {

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return regex
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }


    private func log(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }
}


// MARK: - Errors

enum ServiceError: LocalizedError {

    case cityNotFound
    case invalidURL
    case sourceUnavailable(detail: String)
    case invalidResponse
    case noDutyPharmacyFound

    var diagnosticText: String {
        switch self {
        case .cityNotFound:         return "şehir belirlenemedi"
        case .invalidURL:           return "geçersiz adres"
        case .sourceUnavailable(let detail): return detail
        case .invalidResponse:      return "yanıt okunamadı"
        case .noDutyPharmacyFound:  return "listede kayıt yok"
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
            return "Bulunduğun bölgede bugün için yayınlanmış nöbetçi eczane bulunamadı."
        }
    }
}
