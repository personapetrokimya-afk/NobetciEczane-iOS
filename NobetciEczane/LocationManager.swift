import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    /// Şu anda cihazdan konum ölçümü bekleniyor mu?
    @Published var isLocating = false

    private let manager = CLLocationManager()

    // Aynı anda birden fazla yer konum bekleyebilir (açılıştaki tazeleme +
    // kullanıcının bastığı arama gibi). Hepsi tek ölçümü paylaşır ve
    // ölçüm gelince hep birlikte devam eder.
    private var locationWaiters: [CheckedContinuation<CLLocation, Error>] = []
    private var authorizationWaiters: [CheckedContinuation<Void, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    /// Bu kadar yeni ve isabetli bir ölçüm varsa GPS'i yeniden beklemeye gerek yok.
    private let reuseWindow: TimeInterval = 120
    private let reuseAccuracy: CLLocationAccuracy = 300

    /// Cihazdan güncel konumu ister.
    /// Halihazırda bir ölçüm sürüyorsa hata vermez; o ölçümü BEKLER.
    /// Son 2 dakika içinde alınmış isabetli bir ölçüm varsa GPS beklemeden
    /// HEMEN onu döndürür (eczane araması için 300 m hassasiyet fazlasıyla yeterli);
    /// arka planda yine de taze ölçüm başlatır ki rozet güncel kalsın.
    func requestCurrentLocation() async throws -> CLLocation {

        try await ensureAuthorization()

        if let cached = location,
           -cached.timestamp.timeIntervalSinceNow < reuseWindow,
           cached.horizontalAccuracy >= 0,
           cached.horizontalAccuracy <= reuseAccuracy {

            // Taze ölçümü arka planda başlat; bekletme.
            if !isLocating {
                isLocating = true
                manager.requestLocation()
            }

            return cached
        }

        return try await withCheckedThrowingContinuation { continuation in

            locationWaiters.append(continuation)

            // Ölçüm zaten sürüyorsa yenisini başlatma, sıraya gir.
            guard !isLocating else { return }

            isLocating = true
            manager.requestLocation()
        }
    }

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
                authorizationWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }

        @unknown default:
            throw LocationError.permissionDenied
        }
    }

    private func finishLocation(_ result: Result<CLLocation, Error>) {

        let waiters = locationWaiters
        locationWaiters.removeAll()
        isLocating = false

        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func finishAuthorization(_ result: Result<Void, Error>) {

        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()

        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {

        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {

        case .authorizedAlways, .authorizedWhenInUse:
            finishAuthorization(.success(()))

        case .denied, .restricted:
            finishAuthorization(.failure(LocationError.permissionDenied))
            finishLocation(.failure(LocationError.permissionDenied))

        case .notDetermined:
            break

        @unknown default:
            break
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }

        location = latest
        errorMessage = nil

        finishLocation(.success(latest))
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        errorMessage = error.localizedDescription

        // Elimizde daha önce alınmış bir konum varsa onu kullan,
        // kullanıcıyı boş yere hataya düşürme.
        if let location {
            finishLocation(.success(location))
        } else {
            finishLocation(.failure(error))
        }
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
            return "Konum güncelleniyor. Lütfen bekleyin."
        }
    }
}
