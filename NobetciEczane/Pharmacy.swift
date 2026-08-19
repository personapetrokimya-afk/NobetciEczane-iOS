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

    func distance(from location: CLLocation) -> CLLocationDistance? {
        guard let latitude, let longitude else { return nil }
        return location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }
}
