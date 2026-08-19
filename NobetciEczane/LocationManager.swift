import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    /// Her çağrıda cihazdan yeni bir tek-seferlik konum ölçümü ister.
    /// Eski kayıtlı koordinatı doğrudan döndürmez.
    func requestCurrentLocation() async throws -> CLLocation {
        try await ensureAuthorization()

        if locationContinuation != nil {
            throw LocationError.requestAlreadyInProgress
        }

        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    /// Uygulama açılırken/öne gelirken mevcut konumu sessizce tazelemek için.
    @discardableResult
    func refreshCurrentLocation() async throws -> CLLocation {
        try await requestCurrentLocation()
    }

    private func ensureAuthorization() async throws {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return

        case .denied, .restricted:
            throw LocationError.permissionDenied

        case .notDetermined:
            try await withCheckedThrowingContinuation { continuation in
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }

        @unknown default:
            throw LocationError.permissionDenied
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationContinuation?.resume()
            authorizationContinuation = nil

        case .denied, .restricted:
            let error = LocationError.permissionDenied
            authorizationContinuation?.resume(throwing: error)
            authorizationContinuation = nil
            locationContinuation?.resume(throwing: error)
            locationContinuation = nil

        case .notDetermined:
            break

        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        location = latest
        errorMessage = nil
        locationContinuation?.resume(returning: latest)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
}

enum LocationError: LocalizedError {
    case permissionDenied
    case requestAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Konum izni kapalı. Ayarlar > Gizlilik ve Güvenlik > Konum Servisleri bölümünden izin verin."
        case .requestAlreadyInProgress:
            return "Konum güncelleniyor. Lütfen bir an sonra tekrar deneyin."
        }
    }
}
