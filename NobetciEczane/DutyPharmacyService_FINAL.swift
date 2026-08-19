import Foundation
import CoreLocation

struct DutyPharmacyService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "tr-TR,tr;q=0.9,en;q=0.7"
        ]
        self.session = URLSession(configuration: config)
    }

    func fetchNearest(to location: CLLocation) async throws -> [Pharmacy] {
        let placemark = try await reverseGeocode(location)
        guard let city = placemark.administrativeArea ?? placemark.locality else {
            throw ServiceError.cityNotFound
        }

        let district = placemark.subAdministrativeArea ?? placemark.subLocality ?? placemark.locality

        // Yalnızca doğrulanmış nöbetçi eczane kaynağını kullanır.
        // Apple Maps / genel POI araması ASLA nöbetçi eczane kaynağı olarak kullanılmaz.
        // Kaynak erişilemezse hata döner; normal bir eczane nöbetçi gibi gösterilmez.
        let pharmacies = try await fetchDutyPharmacies(city: city, district: district)
        return sort(pharmacies, around: location)
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> CLPlacemark {
        let marks = try await CLGeocoder().reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "tr_TR")
        )
        guard let mark = marks.first else { throw ServiceError.cityNotFound }
        return mark
    }

    private func fetchDutyPharmacies(city: String, district: String?) async throws -> [Pharmacy] {
        let citySlug = slugify(city)
        guard let url = URL(string: "https://www.eczaneler.gen.tr/nobetci-eczaneler/\(citySlug)") else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("https://www.eczaneler.gen.tr/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw ServiceError.sourceUnavailable
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ServiceError.invalidResponse
        }

        var results = parsePharmacies(from: html)

        if let district, !district.isEmpty {
            let needle = normalize(district)
            let districtMatches = results.filter {
                let itemDistrict = normalize($0.district ?? "")
                let itemAddress = normalize($0.address)
                return itemDistrict.contains(needle) || itemAddress.contains(needle)
            }

            // İlçe bulunduysa yalnızca o ilçenin sonuçları kabul edilir.
            // Eşleşme yoksa şehir geneline geri düşmeyiz; aksi halde yakındaki
            // normal/yanlış eczane "nöbetçi" gibi görünebilir.
            guard !districtMatches.isEmpty else {
                throw ServiceError.noDutyPharmacyFound
            }
            results = districtMatches
        }

        guard !results.isEmpty else {
            throw ServiceError.noDutyPharmacyFound
        }
        return results
    }

    private func sort(_ pharmacies: [Pharmacy], around location: CLLocation) -> [Pharmacy] {
        pharmacies.sorted { lhs, rhs in
            let dl = lhs.distance(from: location) ?? .greatestFiniteMagnitude
            let dr = rhs.distance(from: location) ?? .greatestFiniteMagnitude
            return dl < dr
        }
    }

    private func parsePharmacies(from html: String) -> [Pharmacy] {
        let blocks = regexMatches(
            #"(?is)<div[^>]+class=[\"'][^\"']*(?:eczane|card)[^\"']*[\"'][^>]*>.*?</div>\s*</div>"#,
            in: html
        )
        let candidates = blocks.isEmpty
            ? regexMatches(#"(?is)<article\b.*?</article>"#, in: html)
            : blocks

        var items: [Pharmacy] = []

        for raw in candidates {
            let text = cleanHTML(raw)
            guard text.lowercased().contains("eczane") else { continue }

            let name = firstMatch(
                #"(?is)<(?:h1|h2|h3|h4|strong)[^>]*>(.*?)</(?:h1|h2|h3|h4|strong)>"#,
                in: raw
            ).map(cleanHTML)
            ?? text.components(separatedBy: "\n").first(where: {
                $0.lowercased().contains("ecz")
            })

            guard let name, !name.isEmpty else { continue }

            let phone = firstMatch(
                #"(?i)(?:tel:|0\s*\(?\d{3}\)?)[^\"'<]{7,18}"#,
                in: raw
            ).map {
                cleanHTML($0).replacingOccurrences(of: "tel:", with: "")
            }

            let district = firstMatch(
                #"(?is)<[^>]+class=[\"'][^\"']*(?:ilce|district)[^\"']*[\"'][^>]*>(.*?)</[^>]+>"#,
                in: raw
            ).map(cleanHTML)

            let address = firstMatch(
                #"(?is)<[^>]+class=[\"'][^\"']*(?:adres|address)[^\"']*[\"'][^>]*>(.*?)</[^>]+>"#,
                in: raw
            ).map(cleanHTML)
            ?? text.components(separatedBy: "\n").dropFirst().first(where: { $0.count > 10 })
            ?? "Adres bilgisi"

            let coords = extractCoordinates(raw)

            items.append(
                Pharmacy(
                    name: name,
                    address: address,
                    phone: phone,
                    latitude: coords?.0,
                    longitude: coords?.1,
                    district: district
                )
            )
        }

        var seen = Set<String>()
        return items.filter {
            seen.insert(normalize($0.name + $0.address)).inserted
        }
    }

    private func extractCoordinates(_ text: String) -> (Double, Double)? {
        let patterns = [
            #"(?i)(?:q=|query=|destination=)(-?\d{2}\.\d+),\s*(-?\d{2}\.\d+)"#,
            #"(?i)(?:lat|latitude)[\"'=:\s]+(-?\d{2}\.\d+).*?(?:lng|lon|longitude)[\"'=:\s]+(-?\d{2}\.\d+)"#
        ]

        for pattern in patterns {
            if let groups = captureGroups(pattern, in: text),
               groups.count >= 3,
               let lat = Double(groups[1]),
               let lon = Double(groups[2]) {
                return (lat, lon)
            }
        }
        return nil
    }

    private func slugify(_ value: String) -> String {
        normalize(value)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "ğ", with: "g")
            .replacingOccurrences(of: "ü", with: "u")
            .replacingOccurrences(of: "ş", with: "s")
            .replacingOccurrences(of: "ö", with: "o")
            .replacingOccurrences(of: "ç", with: "c")
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "tr_TR")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanHTML(_ input: String) -> String {
        let noTags = input.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "\n",
            options: .regularExpression
        )

        return noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        ).map {
            ns.substring(with: $0.range)
        }
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let groups = captureGroups(pattern, in: text) else { return nil }
        return groups.count > 1 ? groups[1] : groups.first
    }

    private func captureGroups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        ) else {
            return nil
        }

        return (0..<match.numberOfRanges).compactMap {
            let range = match.range(at: $0)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }
}

enum ServiceError: LocalizedError {
    case cityNotFound
    case invalidURL
    case sourceUnavailable
    case invalidResponse
    case noDutyPharmacyFound

    var errorDescription: String? {
        switch self {
        case .cityNotFound:
            return "Bulunduğun şehir belirlenemedi."
        case .invalidURL:
            return "Nöbetçi eczane adresi oluşturulamadı."
        case .sourceUnavailable:
            return "Nöbetçi eczane bilgisine şu anda ulaşılamıyor."
        case .invalidResponse:
            return "Nöbetçi eczane verisi okunamadı."
        case .noDutyPharmacyFound:
            return "Bulunduğun bölgede nöbetçi eczane bulunamadı."
        }
    }
}
