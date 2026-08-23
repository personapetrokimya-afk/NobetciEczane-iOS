import Foundation
import CoreLocation

struct Pharmacy: Identifiable, Hashable {

    /// Listedeki iki başlık.
    enum Kind: String {
        /// O gün resmî nöbet listesinde olan eczane (gece de açık).
        case duty
        /// Nöbetçi değil ama normal mesaisi gereği ŞU AN açık olan eczane.
        case openNow
    }

    let name: String
    let address: String
    let phone: String?
    let latitude: Double?
    let longitude: Double?
    let district: String?

    /// Bu kaydı doğrulayan kaynaklar (çapraz sorgu).
    /// Birden fazla kaynak aynı eczaneyi bildiriyorsa güven yüksektir.
    var sources: [String] = []

    /// Hangi başlıkta gösterilecek.
    var kind: Kind = .duty

    /// Nöbetin bittiği an (nöbetçiler için). Geçmişse kayıt listelenmez.
    var dutyEndsAt: Date? = nil

    /// Normal mesai kapanış anı (şu an açık eczaneler için).
    var closesAt: Date? = nil

    /// Kararlı kimlik. Kayıtlar kaynaklar birleşirken yeniden kurulduğu için
    /// UUID her yenilemede değişiyor, liste satırları boş yere yeniden çiziliyordu.
    var id: String {
        [
            kind.rawValue,
            PharmacyText.normalize(name),
            PharmacyText.normalize(district ?? ""),
            String(PharmacyText.normalize(address).prefix(20))
        ]
        .joined(separator: "|")
    }

    /// En az iki bağımsız kaynak aynı eczaneyi nöbetçi gösteriyor.
    var isCrossVerified: Bool { sources.count >= 2 }

    /// Satırda gösterilecek açıklık metni.
    var availabilityText: String {

        switch kind {

        case .duty:
            guard let dutyEndsAt else { return "Nöbetçi" }
            return "Nöbetçi · \(PharmacyHours.untilText(dutyEndsAt))"

        case .openNow:
            guard let closesAt else { return "Şu an açık" }
            return "Şu an açık · \(PharmacyHours.untilText(closesAt))"
        }
    }

    /// Kapanışa az kaldıysa kullanıcıyı uyar.
    var isClosingSoon: Bool {

        guard kind == .openNow, let closesAt else { return false }

        let minutes = closesAt.timeIntervalSinceNow / 60

        return minutes > 0 && minutes <= Double(PharmacyHours.closingSoonMinutes)
    }

    func distance(from location: CLLocation) -> CLLocationDistance? {
        guard let latitude, let longitude else { return nil }
        return location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }

    static func == (lhs: Pharmacy, rhs: Pharmacy) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
