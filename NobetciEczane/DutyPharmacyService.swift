import Foundation
import CoreLocation

struct DutyPharmacyService {

    // MARK: - Session

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral

        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true

        // Cache KULLANMA.
        // Uygulama her sorguda güncel nöbetçi listesini ister.
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil

        config.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
                "Version/18.0 Mobile/15E148 Safari/604.1",

            "Accept":
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",

            "Accept-Language":
                "tr-TR,tr;q=0.9,en-US;q=0.7,en;q=0.6",

            "Cache-Control":
                "no-cache",

            "Pragma":
                "no-cache"
        ]

        self.session = URLSession(configuration: config)
    }


    // MARK: - Public

    func fetchNearest(to location: CLLocation) async throws -> [Pharmacy] {

        // Her çağrıda verilen GÜNCEL telefon konumundan şehir/ilçe belirlenir.
        let placemark = try await reverseGeocode(location)

        guard let city = detectCity(from: placemark),
              !city.isEmpty else {
            throw ServiceError.cityNotFound
        }

        let district = detectDistrict(from: placemark)

        print("==========================================")
        print("📍 Şehir: \(city)")
        print("📍 İlçe: \(district ?? "Bilinmiyor")")
        print("==========================================")

        // Yalnızca GERÇEK nöbetçi kaynağı.
        // Apple Maps / normal eczane fallback YOK.
        var pharmacies = try await fetchDutyPharmacies(
            city: city,
            district: district
        )

        // Sayfadan koordinat çıkmayan kayıtların koordinatını
        // adres üzerinden tamamlamayı dene.
        pharmacies = await enrichMissingCoordinates(
            pharmacies,
            city: city,
            district: district
        )

        let sorted = sort(
            pharmacies,
            around: location
        )

        guard !sorted.isEmpty else {
            throw ServiceError.noDutyPharmacyFound
        }

        return sorted
    }


    // MARK: - Location

    private func reverseGeocode(
        _ location: CLLocation
    ) async throws -> CLPlacemark {

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


    private func detectCity(
        from placemark: CLPlacemark
    ) -> String? {

        // Türkiye'de administrativeArea genellikle il bilgisidir.
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


    private func detectDistrict(
        from placemark: CLPlacemark
    ) -> String? {

        let candidates: [String?] = [
            placemark.subAdministrativeArea,
            placemark.locality,
            placemark.subLocality
        ]

        for candidate in candidates {
            guard let value = candidate else {
                continue
            }

            let cleaned = cleanLocationName(value)

            guard !cleaned.isEmpty else {
                continue
            }

            // Şehir adıyla aynı değeri ilçe olarak kullanma.
            if let city = detectCity(from: placemark),
               normalize(cleaned) == normalize(city) {
                continue
            }

            return cleaned
        }

        return nil
    }


    private func cleanLocationName(
        _ value: String
    ) -> String {

        value
            .replacingOccurrences(
                of: " İli",
                with: "",
                options: .caseInsensitive
            )
            .replacingOccurrences(
                of: " İlçesi",
                with: "",
                options: .caseInsensitive
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }


    // MARK: - eczaneler.gen.tr

    private func fetchDutyPharmacies(
        city: String,
        district: String?
    ) async throws -> [Pharmacy] {

        let citySlug = citySlug(city)

        /*
         DOĞRU URL YAPISI:

         İzmir:
         https://www.eczaneler.gen.tr/nobetci-izmir

         Ankara:
         https://www.eczaneler.gen.tr/nobetci-ankara

         Adana:
         https://www.eczaneler.gen.tr/nobetci-adana

         Aydın:
         https://www.eczaneler.gen.tr/nobetci-aydin
        */

        let urlString =
            "https://www.eczaneler.gen.tr/nobetci-\(citySlug)"

        guard let url = URL(string: urlString) else {
            throw ServiceError.invalidURL
        }

        print("🌐 Nöbetçi URL:")
        print(url.absoluteString)

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )

        request.httpMethod = "GET"

        request.setValue(
            "https://www.eczaneler.gen.tr/",
            forHTTPHeaderField: "Referer"
        )

        request.setValue(
            "no-cache",
            forHTTPHeaderField: "Cache-Control"
        )

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("❌ Kaynak bağlantı hatası:")
            print(error.localizedDescription)
            throw ServiceError.sourceUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        print("🌐 HTTP: \(http.statusCode)")

        guard (200...299).contains(http.statusCode) else {
            throw ServiceError.sourceUnavailable
        }

        guard !data.isEmpty else {
            throw ServiceError.invalidResponse
        }

        let html =
            String(data: data, encoding: .utf8)
            ??
            String(data: data, encoding: .isoLatin1)

        guard let html,
              !html.isEmpty else {
            throw ServiceError.invalidResponse
        }

        print("📄 HTML byte: \(data.count)")

        var pharmacies = parsePharmacies(
            from: html,
            city: city
        )

        print(
            "💊 Sayfadan bulunan kayıt: \(pharmacies.count)"
        )

        guard !pharmacies.isEmpty else {
            throw ServiceError.noDutyPharmacyFound
        }

        // İlçe bilgisi varsa SADECE o ilçenin nöbetçilerini kabul et.
        if let district,
           !district.trimmingCharacters(
                in: .whitespacesAndNewlines
           ).isEmpty {

            let districtNeedle = normalize(district)

            let districtMatches =
                pharmacies.filter { pharmacy in

                    let pharmacyDistrict =
                        normalize(
                            pharmacy.district ?? ""
                        )

                    let address =
                        normalize(
                            pharmacy.address
                        )

                    return
                        pharmacyDistrict.contains(
                            districtNeedle
                        )
                        ||
                        districtNeedle.contains(
                            pharmacyDistrict
                        )
                        && !pharmacyDistrict.isEmpty
                        ||
                        address.contains(
                            districtNeedle
                        )
                }

            print(
                "🏘 \(district) eşleşmesi: \(districtMatches.count)"
            )

            /*
             ÇOK ÖNEMLİ:

             Pursaklar bulunamadı diye Ankara'nın başka
             ilçesindeki eczaneyi göstermiyoruz.

             Menemen bulunamadı diye Bornova/Buca vb.
             göstermiyoruz.
            */
            guard !districtMatches.isEmpty else {
                throw ServiceError.noDutyPharmacyFound
            }

            pharmacies = districtMatches
        }

        return pharmacies
    }


    // MARK: - HTML Parser

    private func parsePharmacies(
        from html: String,
        city: String
    ) -> [Pharmacy] {

        /*
         Site HTML yapısı değişebilirse tek CSS class'a
         bağlı kalmıyoruz.

         Önce olası kart/blok yapıları çıkarılıyor.
        */

        var blocks: [String] = []

        let blockPatterns = [

            #"(?is)<div[^>]*class=["'][^"']*(?:eczane|pharmacy|card)[^"']*["'][^>]*>.*?</div>\s*</div>"#,

            #"(?is)<div[^>]*class=["'][^"']*(?:eczane|pharmacy|card)[^"']*["'][^>]*>.*?</div>"#,

            #"(?is)<article\b[^>]*>.*?</article>"#,

            #"(?is)<li\b[^>]*>.*?eczane.*?</li>"#,

            #"(?is)<tr\b[^>]*>.*?eczane.*?</tr>"#
        ]

        for pattern in blockPatterns {

            let found = regexMatches(
                pattern,
                in: html
            )

            if !found.isEmpty {
                blocks.append(contentsOf: found)
            }
        }

        /*
         Kart bulunamazsa daha geniş parçalar deniyoruz.
        */
        if blocks.isEmpty {

            blocks = regexMatches(
                #"(?is).{0,1500}eczane.{0,2500}"#,
                in: html
            )
        }

        var pharmacies: [Pharmacy] = []

        for rawBlock in blocks {

            let text = cleanHTML(rawBlock)

            let normalizedText = normalize(text)

            guard normalizedText.contains("eczane") else {
                continue
            }

            guard let name = extractName(
                rawBlock,
                text: text
            ) else {
                continue
            }

            /*
             Menü, başlık, reklam vb. içerikleri ele.
            */
            let normalizedName = normalize(name)

            if normalizedName.contains(
                "nobetci eczaneler"
            ) {
                continue
            }

            if normalizedName ==
                "eczaneler" {
                continue
            }

            if name.count < 3 ||
                name.count > 100 {
                continue
            }

            let address =
                extractAddress(
                    rawBlock,
                    text: text,
                    name: name
                )

            let phone =
                extractPhone(
                    rawBlock
                )

            let district =
                extractDistrict(
                    rawBlock,
                    text: text
                )

            let coordinates =
                extractCoordinates(
                    rawBlock
                )

            let pharmacy = Pharmacy(
                name: name,
                address: address,
                phone: phone,
                latitude: coordinates?.0,
                longitude: coordinates?.1,
                district: district
            )

            pharmacies.append(pharmacy)
        }

        return removeDuplicates(pharmacies)
    }


    private func extractName(
        _ raw: String,
        text: String
    ) -> String? {

        let patterns = [

            #"(?is)<h1[^>]*>(.*?)</h1>"#,
            #"(?is)<h2[^>]*>(.*?)</h2>"#,
            #"(?is)<h3[^>]*>(.*?)</h3>"#,
            #"(?is)<h4[^>]*>(.*?)</h4>"#,

            #"(?is)<[^>]+class=["'][^"']*(?:eczaneadi|eczane-adi|pharmacy-name|name|title)[^"']*["'][^>]*>(.*?)</[^>]+>"#,

            #"(?is)<strong[^>]*>(.*?)</strong>"#,
            #"(?is)<b[^>]*>(.*?)</b>"#
        ]

        for pattern in patterns {

            if let match =
                firstMatch(
                    pattern,
                    in: raw
                ) {

                let value = cleanHTML(match)

                if isPossiblePharmacyName(value) {
                    return cleanPharmacyName(value)
                }
            }
        }

        // HTML başlığı bulunamadıysa satırlar arasında
        // "eczane" geçen makul satırı ara.
        let lines =
            text
                .components(separatedBy: .newlines)
                .map {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }
                .filter {
                    !$0.isEmpty
                }

        for line in lines {

            if isPossiblePharmacyName(line) {
                return cleanPharmacyName(line)
            }
        }

        return nil
    }


    private func isPossiblePharmacyName(
        _ value: String
    ) -> Bool {

        let normalizedValue = normalize(value)

        guard normalizedValue.contains("eczane")
                || normalizedValue.contains("ecz.")
        else {
            return false
        }

        if normalizedValue.contains(
            "nobetci eczaneler"
        ) {
            return false
        }

        if normalizedValue.contains(
            "eczaneleri listele"
        ) {
            return false
        }

        if value.count < 3 ||
            value.count > 100 {
            return false
        }

        return true
    }


    private func cleanPharmacyName(
        _ value: String
    ) -> String {

        var result =
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return result
    }


    private func extractAddress(
        _ raw: String,
        text: String,
        name: String
    ) -> String {

        let patterns = [

            #"(?is)<[^>]+class=["'][^"']*(?:adres|address)[^"']*["'][^>]*>(.*?)</[^>]+>"#,

            #"(?is)(?:Adres|ADRES)\s*:?\s*</?[^>]*>\s*(.{10,250}?)(?:<br|</div>|</p>)"#
        ]

        for pattern in patterns {

            if let result =
                firstMatch(
                    pattern,
                    in: raw
                ) {

                let cleaned =
                    cleanHTML(result)

                if cleaned.count >= 5 {
                    return cleaned
                }
            }
        }

        let lines =
            text
                .components(separatedBy: .newlines)
                .map {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }
                .filter {
                    !$0.isEmpty
                }

        let normalizedName =
            normalize(name)

        for line in lines {

            let normalizedLine =
                normalize(line)

            if normalizedLine ==
                normalizedName {
                continue
            }

            if looksLikeAddress(line) {
                return line
            }
        }

        return "Adres bilgisi"
    }


    private func looksLikeAddress(
        _ value: String
    ) -> Bool {

        let v = normalize(value)

        let addressWords = [
            "mah",
            "mahalle",
            "cad",
            "cadde",
            "sok",
            "sokak",
            "sk",
            "bulvar",
            "blv",
            "no:",
            "no ",
            "mevki",
            "yolu"
        ]

        return addressWords.contains {
            v.contains($0)
        }
    }


    private func extractPhone(
        _ raw: String
    ) -> String? {

        let patterns = [

            #"(?i)tel:\s*([+0-9 ()-]{10,22})"#,

            #"(?i)(0\s*\(?\d{3}\)?[\s.-]*\d{3}[\s.-]*\d{2}[\s.-]*\d{2})"#,

            #"(?i)(\+90\s*\(?\d{3}\)?[\s.-]*\d{3}[\s.-]*\d{2}[\s.-]*\d{2})"#
        ]

        for pattern in patterns {

            if let result =
                firstMatch(
                    pattern,
                    in: raw
                ) {

                let cleaned =
                    cleanHTML(result)
                        .replacingOccurrences(
                            of: "tel:",
                            with: "",
                            options: .caseInsensitive
                        )
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )

                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        return nil
    }


    private func extractDistrict(
        _ raw: String,
        text: String
    ) -> String? {

        let patterns = [

            #"(?is)<[^>]+class=["'][^"']*(?:ilce|ilçe|district)[^"']*["'][^>]*>(.*?)</[^>]+>"#,

            #"(?is)(?:İlçe|ILCE|İLÇE)\s*:?\s*([^<\n]{2,80})"#
        ]

        for pattern in patterns {

            if let result =
                firstMatch(
                    pattern,
                    in: raw
                ) {

                let cleaned =
                    cleanHTML(result)
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )

                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        /*
         Bazı kartlarda ilçe ayrı field değildir.
         Bu durumda nil bırakıyoruz; adres filtresi
         yine ilçeyi yakalayabilir.
        */

        return nil
    }


    // MARK: - Coordinates

    private func extractCoordinates(
        _ text: String
    ) -> (Double, Double)? {

        let patterns = [

            #"(?i)(?:q=|query=|destination=|daddr=)(-?\d{2}\.\d+),\s*(-?\d{2}\.\d+)"#,

            #"(?i)(?:lat|latitude)["'=:\s]+(-?\d{2}\.\d+).*?(?:lng|lon|longitude)["'=:\s]+(-?\d{2}\.\d+)"#,

            #"(?i)(?:center=)(-?\d{2}\.\d+),\s*(-?\d{2}\.\d+)"#
        ]

        for pattern in patterns {

            if let groups =
                captureGroups(
                    pattern,
                    in: text
                ),
               groups.count >= 3,
               let lat = Double(groups[1]),
               let lon = Double(groups[2]),
               isTurkeyCoordinate(
                    latitude: lat,
                    longitude: lon
               ) {

                return (lat, lon)
            }
        }

        return nil
    }


    private func isTurkeyCoordinate(
        latitude: Double,
        longitude: Double
    ) -> Bool {

        latitude >= 35 &&
        latitude <= 43 &&
        longitude >= 25 &&
        longitude <= 46
    }


    private func enrichMissingCoordinates(
        _ pharmacies: [Pharmacy],
        city: String,
        district: String?
    ) async -> [Pharmacy] {

        var result: [Pharmacy] = []

        /*
         Apple Maps'te "eczane araması" YAPILMIYOR.

         CLGeocoder yalnızca resmi nöbetçi kaynaktan
         gelen ADRESİ koordinata çevirmek için kullanılıyor.
        */

        for pharmacy in pharmacies {

            if pharmacy.latitude != nil,
               pharmacy.longitude != nil {

                result.append(pharmacy)
                continue
            }

            guard pharmacy.address != "Adres bilgisi" else {

                result.append(pharmacy)
                continue
            }

            var addressParts: [String] = [
                pharmacy.address
            ]

            if let district,
               !district.isEmpty {

                addressParts.append(district)
            }

            addressParts.append(city)
            addressParts.append("Türkiye")

            let query =
                addressParts.joined(
                    separator: ", "
                )

            let geocoder = CLGeocoder()

            do {

                let marks =
                    try await geocoder.geocodeAddressString(
                        query
                    )

                if let coordinate =
                    marks.first?
                        .location?
                        .coordinate {

                    let updated = Pharmacy(
                        name: pharmacy.name,
                        address: pharmacy.address,
                        phone: pharmacy.phone,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        district: pharmacy.district
                    )

                    result.append(updated)

                } else {

                    result.append(pharmacy)
                }

            } catch {

                result.append(pharmacy)
            }

            // Geocoder'a aşırı hızlı istek göndermemek için
            // küçük bekleme.
            try? await Task.sleep(
                nanoseconds: 120_000_000
            )
        }

        return result
    }


    // MARK: - Distance

    private func sort(
        _ pharmacies: [Pharmacy],
        around location: CLLocation
    ) -> [Pharmacy] {

        pharmacies.sorted { lhs, rhs in

            let left =
                lhs.distance(from: location)
                ??
                .greatestFiniteMagnitude

            let right =
                rhs.distance(from: location)
                ??
                .greatestFiniteMagnitude

            return left < right
        }
    }


    // MARK: - Duplicate Protection

    private func removeDuplicates(
        _ pharmacies: [Pharmacy]
    ) -> [Pharmacy] {

        var seen = Set<String>()

        return pharmacies.filter {

            let key =
                normalize(
                    $0.name
                    + "|"
                    + $0.address
                )

            return seen.insert(key).inserted
        }
    }


    // MARK: - City Slug

    private func citySlug(
        _ city: String
    ) -> String {

        /*
         eczaneler.gen.tr URL biçimi:

         İzmir       -> izmir
         Aydın       -> aydin
         Ankara      -> ankara
         Şanlıurfa   -> sanliurfa
         Kahramanmaraş -> kahramanmaras
         Iğdır       -> igdir
         Çanakkale   -> canakkale
        */

        var value =
            city
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .lowercased(
                    with: Locale(
                        identifier: "tr_TR"
                    )
                )

        let replacements: [
            String: String
        ] = [
            "ç": "c",
            "ğ": "g",
            "ı": "i",
            "i̇": "i",
            "ö": "o",
            "ş": "s",
            "ü": "u",
            "â": "a",
            "î": "i",
            "û": "u"
        ]

        for (source, target)
            in replacements {

            value =
                value.replacingOccurrences(
                    of: source,
                    with: target
                )
        }

        value =
            value.folding(
                options: .diacriticInsensitive,
                locale: Locale(
                    identifier: "tr_TR"
                )
            )

        value =
            value.replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: "-",
                options: .regularExpression
            )

        value =
            value.trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "-"
                )
            )

        return value
    }


    // MARK: - Normalize

    private func normalize(
        _ value: String
    ) -> String {

        var output =
            value.lowercased(
                with: Locale(
                    identifier: "tr_TR"
                )
            )

        let replacements: [
            String: String
        ] = [
            "ç": "c",
            "ğ": "g",
            "ı": "i",
            "i̇": "i",
            "ö": "o",
            "ş": "s",
            "ü": "u"
        ]

        for (source, target)
            in replacements {

            output =
                output.replacingOccurrences(
                    of: source,
                    with: target
                )
        }

        output =
            output.folding(
                options: [
                    .diacriticInsensitive,
                    .caseInsensitive
                ],
                locale: Locale(
                    identifier: "tr_TR"
                )
            )

        output =
            output.replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: " ",
                options: .regularExpression
            )

        output =
            output.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )

        return output.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }


    // MARK: - HTML Cleaner

    private func cleanHTML(
        _ input: String
    ) -> String {

        var text = input

        text =
            text.replacingOccurrences(
                of: #"(?is)<script\b.*?</script>"#,
                with: "",
                options: .regularExpression
            )

        text =
            text.replacingOccurrences(
                of: #"(?is)<style\b.*?</style>"#,
                with: "",
                options: .regularExpression
            )

        text =
            text.replacingOccurrences(
                of: #"(?i)<br\s*/?>"#,
                with: "\n",
                options: .regularExpression
            )

        text =
            text.replacingOccurrences(
                of: #"</(?:div|p|li|tr|h1|h2|h3|h4)>"#,
                with: "\n",
                options: [
                    .regularExpression,
                    .caseInsensitive
                ]
            )

        text =
            text.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: .regularExpression
            )

        let entities: [
            String: String
        ] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&#x27;": "'"
        ]

        for (entity, replacement)
            in entities {

            text =
                text.replacingOccurrences(
                    of: entity,
                    with: replacement
                )
        }

        return text
            .components(
                separatedBy: .newlines
            )
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter {
                !$0.isEmpty
            }
            .joined(
                separator: "\n"
            )
    }


    // MARK: - Regex Helpers

    private func regexMatches(
        _ pattern: String,
        in text: String
    ) -> [String] {

        guard let regex =
            try? NSRegularExpression(
                pattern: pattern,
                options: []
            )
        else {
            return []
        }

        let ns = text as NSString

        let range =
            NSRange(
                location: 0,
                length: ns.length
            )

        return regex
            .matches(
                in: text,
                options: [],
                range: range
            )
            .map {
                ns.substring(
                    with: $0.range
                )
            }
    }


    private func firstMatch(
        _ pattern: String,
        in text: String
    ) -> String? {

        guard let groups =
            captureGroups(
                pattern,
                in: text
            )
        else {
            return nil
        }

        if groups.count > 1 {
            return groups[1]
        }

        return groups.first
    }


    private func captureGroups(
        _ pattern: String,
        in text: String
    ) -> [String]? {

        guard let regex =
            try? NSRegularExpression(
                pattern: pattern,
                options: []
            )
        else {
            return nil
        }

        let ns = text as NSString

        let range =
            NSRange(
                location: 0,
                length: ns.length
            )

        guard let match =
            regex.firstMatch(
                in: text,
                options: [],
                range: range
            )
        else {
            return nil
        }

        var groups: [String] = []

        for index
            in 0..<match.numberOfRanges {

            let matchRange =
                match.range(at: index)

            guard matchRange.location != NSNotFound else {
                groups.append("")
                continue
            }

            groups.append(
                ns.substring(
                    with: matchRange
                )
            )
        }

        return groups
    }
}


// MARK: - Errors

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
            return "Bulunduğun bölgede doğrulanmış nöbetçi eczane bulunamadı."
        }
    }
}
