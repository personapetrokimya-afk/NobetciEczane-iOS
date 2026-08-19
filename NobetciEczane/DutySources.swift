import Foundation

/// Nöbetçi eczane kaynakları.
/// Tek siteye bağlı kalmamak için birden fazla kaynak paralel sorgulanır,
/// sonuçlar birleştirilip çapraz doğrulanır.
enum DutySource: String, CaseIterable {

    case eczanelerGenTr  = "eczaneler.gen.tr"
    case enYakinEczane   = "nobetcienyakineczane.com"
    case eczaneAdresi    = "eczaneadresi.com"

    /// Bu kaynak için denenecek adresler (ilki başarısızsa sıradaki).
    func urls(citySlug: String, districtSlug: String?) -> [URL] {

        var strings: [String] = []

        switch self {

        case .eczanelerGenTr:
            if let districtSlug, !districtSlug.isEmpty {
                strings = [
                    "https://www.eczaneler.gen.tr/nobetci-\(citySlug)-\(districtSlug)",
                    "https://eczaneler.gen.tr/nobetci-\(citySlug)-\(districtSlug)"
                ]
            } else {
                strings = [
                    "https://www.eczaneler.gen.tr/nobetci-\(citySlug)",
                    "https://eczaneler.gen.tr/nobetci-\(citySlug)"
                ]
            }

        case .enYakinEczane:
            if let districtSlug, !districtSlug.isEmpty {
                strings = [
                    "https://nobetcienyakineczane.com/\(citySlug)/\(districtSlug)",
                    "https://nobetcienyakineczane.com/\(citySlug)"
                ]
            } else {
                strings = ["https://nobetcienyakineczane.com/\(citySlug)"]
            }

        case .eczaneAdresi:
            // Bu kaynakta ilçe sayfası eczane detayına gittiği için
            // her durumda il sayfası okunur, ilçe süzmesi bizde yapılır.
            strings = ["https://eczaneadresi.com/\(citySlug)-nobetci-eczane"]
        }

        return strings.compactMap { URL(string: $0) }
    }

    /// Sayfanın tamamı mı okunmalı, yoksa yalnızca ilk (bugünkü) tablo mu?
    /// eczaneler.gen.tr aynı sayfada 3 günlük liste yayınlar; diğerleri yalnızca bugünü.
    var needsTodaySectionCut: Bool {
        self == .eczanelerGenTr
    }
}


/// Çapraz sorgu sonucu.
struct CrossCheckResult {

    var pharmacies: [Pharmacy] = []

    /// Yanıt veren kaynaklar.
    var succeeded: [String] = []

    /// Yanıt vermeyen kaynaklar ve sebepleri (teşhis için).
    var failures: [String] = []

    var isEmpty: Bool { pharmacies.isEmpty }
}


extension DutyPharmacyService {

    /// Tüm kaynakları PARALEL sorgular, sonuçları birleştirir ve çapraz doğrular.
    /// Kaynaklardan biri çökse bile diğerleri veriyi getirir.
    func fetchCrossChecked(
        citySlug: String,
        districtSlug: String?,
        districtName: String?
    ) async -> CrossCheckResult {

        let sources = DutySource.allCases

        var perSource: [(DutySource, [Pharmacy], String?)] = []

        await withTaskGroup(
            of: (DutySource, [Pharmacy], String?).self
        ) { group in

            for source in sources {
                group.addTask {
                    do {
                        let found = try await self.fetch(
                            from: source,
                            citySlug: citySlug,
                            districtSlug: districtSlug,
                            districtName: districtName
                        )
                        return (source, found, nil)
                    } catch let error as ServiceError {
                        return (source, [], error.diagnosticText)
                    } catch {
                        return (source, [], error.localizedDescription)
                    }
                }
            }

            for await item in group {
                perSource.append(item)
            }
        }

        // Kaynak sırası sabitlensin ki sonuç her seferinde aynı olsun.
        let order = DutySource.allCases

        perSource.sort { lhs, rhs in
            (order.firstIndex(of: lhs.0) ?? 0) < (order.firstIndex(of: rhs.0) ?? 0)
        }

        var result = CrossCheckResult()

        let primary = DutySource.eczanelerGenTr

        let primaryList = perSource.first { $0.0 == primary }?.1 ?? []

        if !primaryList.isEmpty {

            // eczaneler.gen.tr yapısı bilinen ve tablo tabanlı kaynaktır: ASIL liste odur.
            // Diğer kaynaklar yalnızca DOĞRULAR ve eksik alanı (koordinat/telefon) tamamlar,
            // listeye yeni kayıt EKLEYEMEZ. Böylece menü/reklam kırıntıları listeye sızmaz.
            result.succeeded.append(primary.rawValue)
            result.pharmacies = primaryList

            for item in perSource where item.0 != primary {

                if item.1.isEmpty {
                    result.failures.append("\(item.0.rawValue): \(item.2 ?? "kayıt yok")")
                    continue
                }

                result.succeeded.append(item.0.rawValue)

                result.pharmacies = merge(
                    result.pharmacies,
                    with: item.1,
                    appendUnmatched: false
                )
            }

            return result
        }

        // Asıl kaynak yanıt vermediyse LİSTE ÜRETİLMEZ.
        // Yedek siteler kart yapılı olduğu için SSS/footer başlıklarını
        // eczane sanıp listeye çöp dolduruyordu. Yanlış liste göstermektense
        // hatayı sebebiyle birlikte göstermek doğrudur.
        result.failures.append(
            "\(primary.rawValue): \(perSource.first { $0.0 == primary }?.2 ?? "kayıt yok")"
        )

        for item in perSource where item.0 != primary {
            result.failures.append(
                "\(item.0.rawValue): \(item.1.isEmpty ? (item.2 ?? "kayıt yok") : "\(item.1.count) kayıt (yalnızca doğrulama için)")"
            )
        }

        return result
    }


    func fetch(
        from source: DutySource,
        citySlug: String,
        districtSlug: String?,
        districtName: String?
    ) async throws -> [Pharmacy] {

        var lastError: ServiceError = .sourceUnavailable(detail: "bilinmiyor")

        for url in source.urls(citySlug: citySlug, districtSlug: districtSlug) {

            do {
                let html = try await fetchHTML(from: url)

                let section = source.needsTodaySectionCut
                    ? extractTodaySection(from: html)
                    : html

                var found = extractPharmacies(
                    from: section,
                    fallbackDistrict: districtName
                )

                // Dönem başlığına göre kesme tutmadıysa sayfanın tamamını dene.
                if found.isEmpty, section.count < html.count {
                    found = extractPharmacies(
                        from: html,
                        fallbackDistrict: districtName
                    )
                }

                found = found.map {
                    var copy = $0
                    copy.sources = [source.rawValue]
                    return copy
                }

                if !found.isEmpty {
                    return removeDuplicates(found)
                }

                // Sayfa geldi ama hiç kayıt çıkmadı: ağ değil, ayrıştırma sorunu.
                let eczanesiCount = ranges(of: #"(?i)eczanesi"#, in: html).count
                let nodeCount = ranges(
                    of: #">\s*([^<>{}]{2,60}?[EeİiIı]czanesi)\s*<"#,
                    in: html
                ).count

                lastError = .sourceUnavailable(
                    detail: "sayfa \(html.count) krk, 'eczanesi' \(eczanesiCount), ad düğümü \(nodeCount), kayıt 0"
                )

            } catch let error as ServiceError {
                lastError = error
            }
        }

        throw lastError
    }


    /// İki kaynağın listesini birleştirir.
    /// Aynı eczane iki kaynakta da varsa tek kayda indirilir,
    /// eksik alanlar (koordinat, telefon, adres) diğer kaynaktan tamamlanır
    /// ve `sources` alanına ikinci kaynak eklenir.
    func merge(
        _ base: [Pharmacy],
        with incoming: [Pharmacy],
        appendUnmatched: Bool = true
    ) -> [Pharmacy] {

        guard !base.isEmpty else { return appendUnmatched ? incoming : [] }

        var merged = base

        for candidate in incoming {

            let candidateKey = matchKey(candidate)

            if let index = merged.firstIndex(where: { matchKey($0) == candidateKey }) {

                var existing = merged[index]

                if existing.latitude == nil || existing.longitude == nil,
                   let lat = candidate.latitude,
                   let lon = candidate.longitude {

                    existing = Pharmacy(
                        name: existing.name,
                        address: existing.address.isEmpty ? candidate.address : existing.address,
                        phone: existing.phone ?? candidate.phone,
                        latitude: lat,
                        longitude: lon,
                        district: existing.district ?? candidate.district,
                        sources: existing.sources
                    )
                } else {
                    existing = Pharmacy(
                        name: existing.name,
                        address: existing.address.isEmpty ? candidate.address : existing.address,
                        phone: existing.phone ?? candidate.phone,
                        latitude: existing.latitude,
                        longitude: existing.longitude,
                        district: existing.district ?? candidate.district,
                        sources: existing.sources
                    )
                }

                for source in candidate.sources where !existing.sources.contains(source) {
                    existing.sources.append(source)
                }

                merged[index] = existing

            } else if appendUnmatched {
                merged.append(candidate)
            }
        }

        return merged
    }


    /// Eşleştirme anahtarı: eczane adı + (varsa) ilçe.
    /// Adresler kaynaklar arasında farklı yazıldığı için ada göre eşleşiriz.
    func matchKey(_ pharmacy: Pharmacy) -> String {

        var name = normalize(pharmacy.name)

        for suffix in [" eczanesi", " eczane"] {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
        }

        let district = normalize(pharmacy.district ?? "")

        return district.isEmpty ? name : "\(name)|\(district)"
    }
}
