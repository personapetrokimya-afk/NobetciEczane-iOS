import Foundation

/// Nöbetçi eczane kaynakları.
///
/// Tek siteye bağlı kalmamak için birden fazla kaynak PARALEL sorgulanır,
/// sonuçlar birleştirilip çapraz doğrulanır. Kaynaklar iki katmandır:
///
/// - `leading == true`  : Yapısı doğrulanmış, listeyi TEK BAŞINA üretebilen kaynak.
/// - `leading == false` : Yalnızca DOĞRULAYAN kaynak. Listeye tek başına kayıt ekleyemez;
///                        eksik alanı (telefon, koordinat, adres) tamamlar ve
///                        aynı eczaneyi bildirerek güven puanını yükseltir.
///
/// Böylece bir sitenin menü/SSS/footer metinleri listeye "eczane" diye sızamaz.
enum DutySource: String, CaseIterable {

    // --- Listeyi üretebilen (doğrulanmış) kaynaklar ---
    case eczanelerGenTr   = "eczaneler.gen.tr"
    case eczaneAdresi     = "eczaneadresi.com"
    case eczanelerOrg     = "eczaneler.org"
    case enYakinEczane    = "nobetcienyakineczane.com"

    // --- Yalnızca doğrulama / tamamlama kaynakları ---
    case nobetciEczaneNet = "nobetcieczane.net"
    case trNobetciEczane  = "trnobetcieczane.com"
    case hastanemYanimda  = "hastanemyanimda.com"
    case nobetciEczaneniz = "nobetcieczaneniz.com"
    case eczaneleriNet    = "eczaneleri.net"
    case nobetciBugun     = "nobetcieczanebugun.com"


    /// Bu kaynak listeyi tek başına üretebilir mi?
    var leading: Bool {
        switch self {
        case .eczanelerGenTr, .eczaneAdresi, .eczanelerOrg, .enYakinEczane:
            return true
        default:
            return false
        }
    }


    /// Öncelik sırası (küçük = önce). Liste, yanıt veren EN ÖNCELİKLİ
    /// kaynağın kayıtları üzerine kurulur.
    var priority: Int {
        switch self {
        case .eczanelerGenTr:   return 0
        case .eczaneAdresi:     return 1
        case .eczanelerOrg:     return 2
        case .enYakinEczane:    return 3
        case .nobetciEczaneNet: return 4
        case .trNobetciEczane:  return 5
        case .hastanemYanimda:  return 6
        case .nobetciEczaneniz: return 7
        case .eczaneleriNet:    return 8
        case .nobetciBugun:     return 9
        }
    }


    /// Sayfada birden çok GÜNÜN listesi bulunduğu için yalnızca bugünkü
    /// dönem kesilmelidir. Diğer kaynaklar zaten sadece bugünü yayınlar.
    var needsTodaySectionCut: Bool {
        self == .eczanelerGenTr
    }


    /// Bu kaynak için denenecek adresler (ilki başarısızsa sıradaki).
    func urls(citySlug: String, districtSlug: String?) -> [URL] {

        let district = (districtSlug?.isEmpty == false) ? districtSlug : nil

        var strings: [String] = []

        switch self {

        case .eczanelerGenTr:
            if let district {
                strings = [
                    "https://www.eczaneler.gen.tr/nobetci-\(citySlug)-\(district)",
                    "https://eczaneler.gen.tr/nobetci-\(citySlug)-\(district)"
                ]
            } else {
                strings = [
                    "https://www.eczaneler.gen.tr/nobetci-\(citySlug)",
                    "https://eczaneler.gen.tr/nobetci-\(citySlug)"
                ]
            }

        case .eczaneAdresi:
            // Bu kaynakta ilçe sayfası eczane detayına gittiği için
            // her durumda il sayfası okunur, ilçe süzmesi bizde yapılır.
            strings = ["https://eczaneadresi.com/\(citySlug)-nobetci-eczane"]

        case .eczanelerOrg:
            if let district {
                strings = [
                    "https://eczaneler.org/\(citySlug)-\(district)-nobetci-eczaneleri",
                    "https://eczaneler.org/\(citySlug)-nobetci-eczaneleri"
                ]
            } else {
                strings = ["https://eczaneler.org/\(citySlug)-nobetci-eczaneleri"]
            }

        case .enYakinEczane:
            if let district {
                strings = [
                    "https://nobetcienyakineczane.com/\(citySlug)/\(district)",
                    "https://nobetcienyakineczane.com/\(citySlug)"
                ]
            } else {
                strings = ["https://nobetcienyakineczane.com/\(citySlug)"]
            }

        case .nobetciEczaneNet:
            if let district {
                strings = [
                    "https://nobetcieczane.net/\(citySlug)-\(district)-nobetci-eczaneler",
                    "https://nobetcieczane.net/\(citySlug)-nobetci-eczaneler"
                ]
            } else {
                strings = ["https://nobetcieczane.net/\(citySlug)-nobetci-eczaneler"]
            }

        case .trNobetciEczane:
            if let district {
                strings = [
                    "https://www.trnobetcieczane.com/ilce/\(citySlug)-\(district)-nobetci-eczaneler/",
                    "https://www.trnobetcieczane.com/il/\(citySlug)-nobetci-eczaneler/"
                ]
            } else {
                strings = ["https://www.trnobetcieczane.com/il/\(citySlug)-nobetci-eczaneler/"]
            }

        case .hastanemYanimda:
            if let district {
                strings = [
                    "https://www.hastanemyanimda.com/nobetci-eczane/\(citySlug)/\(district)",
                    "https://www.hastanemyanimda.com/nobetci-eczane/\(citySlug)"
                ]
            } else {
                strings = ["https://www.hastanemyanimda.com/nobetci-eczane/\(citySlug)"]
            }

        case .nobetciEczaneniz:
            if let district {
                strings = [
                    "https://nobetcieczaneniz.com/nobetci-eczane/\(citySlug)/\(district)",
                    "https://nobetcieczaneniz.com/nobetci-eczane/\(citySlug)"
                ]
            } else {
                strings = ["https://nobetcieczaneniz.com/nobetci-eczane/\(citySlug)"]
            }

        case .eczaneleriNet:
            // Şehir alt alan adı: izmir.eczaneleri.net
            if let district {
                strings = [
                    "https://\(citySlug).eczaneleri.net/\(district)-nobetci-eczaneleri",
                    "https://\(citySlug).eczaneleri.net/"
                ]
            } else {
                strings = ["https://\(citySlug).eczaneleri.net/"]
            }

        case .nobetciBugun:
            if let district {
                strings = [
                    "https://nobetcieczanebugun.com/\(district)-nobetci-eczane-\(citySlug)"
                ]
            } else {
                strings = [
                    "https://nobetcieczanebugun.com/\(citySlug)-nobetci-eczane"
                ]
            }
        }

        return strings.compactMap { URL(string: $0) }
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

    /// Tek bir kaynağın sonucu.
    struct SourceOutcome {

        let source: DutySource

        let pharmacies: [Pharmacy]

        /// Kaynak, listenin BUGÜNE ait olduğunu kanıtladı mı?
        /// (Dönem başlığı bugünle eşleşti ya da sayfada bugünün tarihi geçiyor.)
        let dayVerified: Bool

        let failure: String?
    }


    /// Tüm kaynakları PARALEL sorgular, sonuçları birleştirir ve çapraz doğrular.
    ///
    /// Kural:
    /// 1. Liste, GÜNÜ KANITLAMIŞ en öncelikli "leading" kaynağın kayıtları üzerine kurulur.
    ///    Hiçbir kaynak günü kanıtlayamıyorsa liste ÜRETİLMEZ — yanlış günün listesini
    ///    göstermektense hiç göstermemek doğrudur.
    /// 2. Diğer kaynaklar bu kayıtları doğrular ve eksik alanlarını tamamlar.
    /// 3. Ana listede olmayan bir kayıt, ancak EN AZ İKİ kaynak (en az biri günü
    ///    kanıtlamış olmak üzere) onu bildiriyorsa listeye eklenir.
    func fetchCrossChecked(
        citySlug: String,
        districtSlug: String?,
        districtName: String?
    ) async -> CrossCheckResult {

        var outcomes: [SourceOutcome] = []

        await withTaskGroup(of: SourceOutcome.self) { group in

            for source in DutySource.allCases {
                group.addTask {
                    do {
                        let found = try await self.fetch(
                            from: source,
                            citySlug: citySlug,
                            districtSlug: districtSlug,
                            districtName: districtName
                        )
                        return SourceOutcome(
                            source: source,
                            pharmacies: found.pharmacies,
                            dayVerified: found.dayVerified,
                            failure: nil
                        )
                    } catch let error as ServiceError {
                        return SourceOutcome(
                            source: source,
                            pharmacies: [],
                            dayVerified: false,
                            failure: error.diagnosticText
                        )
                    } catch {
                        return SourceOutcome(
                            source: source,
                            pharmacies: [],
                            dayVerified: false,
                            failure: error.localizedDescription
                        )
                    }
                }
            }

            for await item in group {
                outcomes.append(item)
            }
        }

        // Sonuç her seferinde aynı olsun diye kaynak sırası sabitlenir.
        outcomes.sort { $0.source.priority < $1.source.priority }

        var result = CrossCheckResult()

        // 1) Listeyi kuracak ana kaynak: doğrulanmış, günü kanıtlamış ve dolu.
        guard let base = outcomes.first(where: {
            $0.source.leading && $0.dayVerified && !$0.pharmacies.isEmpty
        }) else {

            for item in outcomes {
                let reason: String
                if let failure = item.failure {
                    reason = failure
                } else if item.pharmacies.isEmpty {
                    reason = "kayıt yok"
                } else if !item.dayVerified {
                    reason = "\(item.pharmacies.count) kayıt ama günü doğrulanamadı"
                } else {
                    reason = "\(item.pharmacies.count) kayıt (yalnızca doğrulama)"
                }
                result.failures.append("\(item.source.rawValue): \(reason)")
            }

            return result
        }

        result.succeeded.append(base.source.rawValue)
        result.pharmacies = base.pharmacies

        // Günü kanıtlamış kaynaklar: ek kayıt ancak bunlardan biriyle doğrulanabilir.
        let verifiedSources = Set(
            outcomes.filter { $0.dayVerified }.map { $0.source.rawValue }
        )

        // 2) Kalan kaynaklarla doğrula / tamamla.
        var extraCandidates: [String: Pharmacy] = [:]
        var extraOrder: [String] = []

        for item in outcomes where item.source != base.source {

            if item.pharmacies.isEmpty {
                result.failures.append("\(item.source.rawValue): \(item.failure ?? "kayıt yok")")
                continue
            }

            result.succeeded.append(item.source.rawValue)

            let baseKeys = Set(result.pharmacies.map { matchKey($0) })

            // Ana listedeki kayıtları doğrula + eksik alanları tamamla.
            result.pharmacies = merge(
                result.pharmacies,
                with: item.pharmacies,
                appendUnmatched: false
            )

            // Ana listede OLMAYAN kayıtlar: en az iki kaynak söylerse eklenecek.
            for candidate in item.pharmacies {

                let key = matchKey(candidate)

                guard !baseKeys.contains(key) else { continue }

                if var existing = extraCandidates[key] {

                    for source in candidate.sources where !existing.sources.contains(source) {
                        existing.sources.append(source)
                    }

                    if existing.latitude == nil,
                       let lat = candidate.latitude,
                       let lon = candidate.longitude {

                        existing = Pharmacy(
                            name: existing.name,
                            address: existing.address.isEmpty ? candidate.address : existing.address,
                            phone: existing.phone ?? candidate.phone,
                            latitude: lat,
                            longitude: lon,
                            district: existing.district ?? candidate.district,
                            sources: existing.sources,
                            kind: existing.kind,
                            dutyEndsAt: existing.dutyEndsAt ?? candidate.dutyEndsAt
                        )
                    }

                    extraCandidates[key] = existing

                } else {
                    extraCandidates[key] = candidate
                    extraOrder.append(key)
                }
            }
        }

        // 3) İki ve daha fazla kaynağın doğruladığı ek kayıtlar listeye girer;
        //    en az biri günü kanıtlamış olmalıdır.
        for key in extraOrder {

            guard let candidate = extraCandidates[key],
                  candidate.sources.count >= 2,
                  candidate.sources.contains(where: { verifiedSources.contains($0) })
            else { continue }

            result.pharmacies.append(candidate)
        }

        return result
    }


    /// Bir kaynaktan bugünün nöbetçi listesini çeker.
    /// `dayVerified`, listenin gerçekten BUGÜNE ait olduğunun kanıtlanıp
    /// kanıtlanamadığını söyler.
    func fetch(
        from source: DutySource,
        citySlug: String,
        districtSlug: String?,
        districtName: String?
    ) async throws -> (pharmacies: [Pharmacy], dayVerified: Bool) {

        var lastError: ServiceError = .sourceUnavailable(detail: "bilinmiyor")

        for url in source.urls(citySlug: citySlug, districtSlug: districtSlug) {

            do {
                let html = try await fetchHTML(from: url)

                // Sayfada bugünün tarihi geçiyor mu? (Gün doğrulamasının temeli.)
                var dayVerified = pageMentionsToday(html)

                var section = html
                var dutyEndsAt = PharmacyHours.dutyEnd(
                    forDutyDate: PharmacyHours.currentDutyDate()
                )

                if source.needsTodaySectionCut {

                    // Sayfa birden çok günü yayınlıyor: yalnızca BUGÜNKÜ dönem okunur.
                    guard let today = todayDutySection(from: html) else {
                        lastError = .dutyListNotPublished
                        log("⏭️ \(url.absoluteString) -> bugünün dönemi sayfada yok")
                        continue
                    }

                    section = today.html
                    dutyEndsAt = today.endsAt ?? dutyEndsAt

                    if today.matchedPeriod { dayVerified = true }
                }

                // Nöbet penceresi kapandıysa bu liste ARTIK GEÇERSİZDİR.
                guard PharmacyHours.isDutyStillActive(endsAt: dutyEndsAt) else {
                    lastError = .dutyListNotPublished
                    continue
                }

                var found = extractPharmacies(
                    from: section,
                    fallbackDistrict: districtName
                )

                found = found.map {
                    var copy = $0
                    copy.sources = [source.rawValue]
                    copy.kind = .duty
                    copy.dutyEndsAt = dutyEndsAt
                    return copy
                }

                if !found.isEmpty {
                    log("💊 \(url.absoluteString) -> \(found.count) kayıt, gün doğrulandı: \(dayVerified)")
                    return (removeDuplicates(found), dayVerified)
                }

                // Sayfa geldi ama hiç kayıt çıkmadı: ağ değil, ayrıştırma sorunu.
                let eczanesiCount = ranges(of: #"(?i)eczanesi"#, in: html).count

                lastError = .sourceUnavailable(
                    detail: "sayfa \(html.count) krk, 'eczanesi' \(eczanesiCount), kayıt 0"
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

            // Aynı eczane, ilçe bilgisi olan ve olmayan iki kaynaktan gelince
            // farklı anahtar üretiyordu; liste aynı eczaneyi iki kez gösteriyordu.
            let index = merged.firstIndex(where: { matchKey($0) == candidateKey })
                ?? merged.firstIndex(where: { looselyMatches($0, candidate) })

            if let index {

                var existing = merged[index]

                let hasOwnCoordinate = existing.latitude != nil && existing.longitude != nil

                var updated = Pharmacy(
                    name: existing.name,
                    address: existing.address.isEmpty ? candidate.address : existing.address,
                    phone: existing.phone ?? candidate.phone,
                    latitude: hasOwnCoordinate ? existing.latitude : candidate.latitude,
                    longitude: hasOwnCoordinate ? existing.longitude : candidate.longitude,
                    district: existing.district ?? candidate.district,
                    sources: existing.sources,
                    kind: existing.kind,
                    dutyEndsAt: existing.dutyEndsAt ?? candidate.dutyEndsAt,
                    closesAt: existing.closesAt ?? candidate.closesAt
                )

                for source in candidate.sources where !updated.sources.contains(source) {
                    updated.sources.append(source)
                }

                existing = updated
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

        let name = nameKey(pharmacy)
        let district = normalize(pharmacy.district ?? "")

        return district.isEmpty ? name : "\(name)|\(district)"
    }


    /// Yalnızca ad: "Melek Eczanesi" -> "melek".
    func nameKey(_ pharmacy: Pharmacy) -> String {

        var name = normalize(pharmacy.name)

        for suffix in [" eczanesi", " eczane"] {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
        }

        return name
    }


    /// Taraflardan birinin ilçesi bilinmiyorsa ada göre eşleşmek yeterlidir.
    /// (Aynı adı taşıyan iki ayrı eczanenin karışmaması için ikisinin de
    /// ilçesi biliniyorsa ilçe şart koşulur.)
    func looselyMatches(_ lhs: Pharmacy, _ rhs: Pharmacy) -> Bool {

        let key = nameKey(lhs)

        guard !key.isEmpty, key == nameKey(rhs) else { return false }

        let left = normalize(lhs.district ?? "")
        let right = normalize(rhs.district ?? "")

        return left.isEmpty || right.isEmpty
    }
}
