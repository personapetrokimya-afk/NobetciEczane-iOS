import Foundation
import CoreLocation

struct Pharmacy: Identifiable, Hashable {

    let id = UUID()
    let name: String
    let address: String
    let phone: String?
    let latitude: Double?
    let longitude: Double?
    let district: String?

    /// Bu kaydı doğrulayan kaynaklar (çapraz sorgu).
    /// Birden fazla kaynak aynı eczaneyi bildiriyorsa güven yüksektir.
    var sources: [String] = []

    /// En az iki bağımsız kaynak aynı eczaneyi nöbetçi gösteriyor.
    var isCrossVerified: Bool { sources.count >= 2 }

    func distance(from location: CLLocation) -> CLLocationDistance? {
        guard let latitude, let longitude else { return nil }
        return location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }

    static func == (lhs: Pharmacy, rhs: Pharmacy) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
