import Foundation
import MapKit
import CoreLocation

/// "Şu an açık eczaneler" listesi.
///
/// Nöbet listeleri yalnızca NÖBETÇİ eczaneleri yayınlar. Oysa gündüz saatlerinde
/// kullanıcının işi çoğu zaman en yakın AÇIK eczanededir. Bu yüzden çevredeki
/// eczaneler Apple Haritalar veri tabanından okunur ve TÜRKİYE SAATİNE göre
/// mesai kontrolünden geçirilir.
///
/// Altın kural: mesai dışında bu liste BOŞ döner. Kapalı bir eczane hiçbir
/// koşulda listelenmez; o saatlerde yalnızca nöbetçiler gösterilir.
struct NearbyOpenPharmacyFinder {

    /// Arama yarıçapı (metre).
    var radius: CLLocationDistance = 7_000

    /// Listede gösterilecek en fazla kayıt.
    var limit: Int = 20


    func openNow(
        around location: CLLocation,
        excluding duty: [Pharmacy],
        now: Date = Date()
    ) async -> [Pharmacy] {

        // Mesai dışıysa "şu an açık" eczane YOKTUR.
        guard PharmacyHours.isOpenNow(now),
              let closesAt = PharmacyHours.closingDate(now) else {
            return []
        }

        var items = await pointsOfInterest(around: location)

        if items.isEmpty {
            items = await textSearch(around: location)
        }

        let excluded = Set(duty.map { Self.key(for: $0.name) })

        var seen = Set<String>()
        var result: [Pharmacy] = []

        for item in items {

            guard let rawName = item.name?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else { continue }

            let key = Self.key(for: rawName)

            // Harita verisinde ecza deposu, kozmetik vb. de çıkabiliyor.
            guard Self.normalized(rawName).contains("eczane"),
                  !key.isEmpty,
                  !excluded.contains(key),
                  seen.insert(key).inserted else { continue }

            let coordinate = item.placemark.coordinate

            result.append(
                Pharmacy(
                    name: rawName,
                    address: Self.address(from: item.placemark),
                    phone: item.phoneNumber,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    district: item.placemark.subAdministrativeArea
                        ?? item.placemark.locality,
                    sources: ["Apple Haritalar"],
                    kind: .openNow,
                    dutyEndsAt: nil,
                    closesAt: closesAt
                )
            )
        }

        let sorted = result.sorted {
            ($0.distance(from: location) ?? .greatestFiniteMagnitude)
                < ($1.distance(from: location) ?? .greatestFiniteMagnitude)
        }

        return Array(sorted.prefix(limit))
    }


    // MARK: - Harita sorguları

    private func pointsOfInterest(around location: CLLocation) async -> [MKMapItem] {

        let request = MKLocalPointsOfInterestRequest(
            center: location.coordinate,
            radius: min(radius, 50_000)
        )

        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.pharmacy])

        guard let response = try? await MKLocalSearch(request: request).start() else {
            return []
        }

        return response.mapItems
    }


    /// Bazı bölgelerde POI sorgusu boş dönebiliyor; metin araması yedektir.
    private func textSearch(around location: CLLocation) async -> [MKMapItem] {

        let request = MKLocalSearch.Request()

        request.naturalLanguageQuery = "eczane"
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.pharmacy])

        guard let response = try? await MKLocalSearch(request: request).start() else {
            return []
        }

        return response.mapItems
    }


    // MARK: - Yardımcılar

    /// Ad karşılaştırma anahtarı: "Melek Eczanesi" ile "MELEK ECZANE" aynı kayıttır.
    static func key(for name: String) -> String {

        var value = normalized(name)

        for suffix in [" eczanesi", " eczane"] {
            if value.hasSuffix(suffix) {
                value = String(value.dropLast(suffix.count))
            }
        }

        return value.trimmingCharacters(in: .whitespaces)
    }


    static func normalized(_ value: String) -> String {

        var output = PharmacyText.normalize(value)

        output = output.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: " ",
            options: .regularExpression
        )

        return output.trimmingCharacters(in: .whitespaces)
    }


    static func address(from placemark: MKPlacemark) -> String {

        let parts: [String?] = [
            placemark.subLocality,
            [placemark.thoroughfare, placemark.subThoroughfare]
                .compactMap { $0 }
                .joined(separator: " No: "),
            placemark.subAdministrativeArea ?? placemark.locality
        ]

        return parts
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
