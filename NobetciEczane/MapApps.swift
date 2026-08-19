import SwiftUI
import MapKit
import UIKit

/// Telefonda YÜKLÜ olan harita uygulamaları.
/// `isInstalled`, Info.plist içindeki `LSApplicationQueriesSchemes` listesine
/// dayanır; orada tanımlı olmayan şema her zaman "yüklü değil" görünür.
enum MapApp: String, CaseIterable, Identifiable {

    case apple
    case google
    case yandexMaps
    case yandexNavi
    case waze

    var id: String { rawValue }

    var name: String {
        switch self {
        case .apple:      return "Apple Haritalar"
        case .google:     return "Google Haritalar"
        case .yandexMaps: return "Yandex Haritalar"
        case .yandexNavi: return "Yandex Navigasyon"
        case .waze:       return "Waze"
        }
    }

    /// Assets.xcassets içine bu adla bir görsel eklenirse gerçek logo kullanılır.
    /// Yoksa aşağıdaki SF Symbol'a düşer.
    var assetName: String {
        switch self {
        case .apple:      return "logo_apple_maps"
        case .google:     return "logo_google_maps"
        case .yandexMaps: return "logo_yandex_maps"
        case .yandexNavi: return "logo_yandex_navi"
        case .waze:       return "logo_waze"
        }
    }

    var systemImage: String {
        switch self {
        case .apple:      return "map.fill"
        case .google:     return "mappin.and.ellipse"
        case .yandexMaps: return "globe.europe.africa.fill"
        case .yandexNavi: return "location.north.circle.fill"
        case .waze:       return "car.fill"
        }
    }

    var tint: Color {
        switch self {
        case .apple:      return .blue
        case .google:     return .green
        case .yandexMaps: return .red
        case .yandexNavi: return .orange
        case .waze:       return .cyan
        }
    }

    /// Yüklü mü diye sorgulanacak şema. Apple Haritalar her iPhone'da vardır.
    private var probeScheme: String? {
        switch self {
        case .apple:      return nil
        case .google:     return "comgooglemaps://"
        case .yandexMaps: return "yandexmaps://"
        case .yandexNavi: return "yandexnavi://"
        case .waze:       return "waze://"
        }
    }

    var isInstalled: Bool {

        guard let probeScheme,
              let url = URL(string: probeScheme) else {
            return true
        }

        return UIApplication.shared.canOpenURL(url)
    }

    /// Telefonda kurulu olan harita uygulamaları.
    static var installed: [MapApp] {
        MapApp.allCases.filter { $0.isInstalled }
    }


    // MARK: - Açma

    func openRoute(to pharmacy: Pharmacy) {

        let latitude = pharmacy.latitude
        let longitude = pharmacy.longitude

        let query = ([pharmacy.name, pharmacy.address]
            .filter { !$0.isEmpty }
            .joined(separator: " "))
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        switch self {

        case .apple:
            if let latitude, let longitude {
                let item = MKMapItem(
                    placemark: MKPlacemark(
                        coordinate: CLLocationCoordinate2D(
                            latitude: latitude,
                            longitude: longitude
                        )
                    )
                )
                item.name = pharmacy.name
                item.openInMaps(
                    launchOptions: [
                        MKLaunchOptionsDirectionsModeKey:
                            MKLaunchOptionsDirectionsModeDriving
                    ]
                )
                return
            }
            open("http://maps.apple.com/?daddr=\(query)&dirflg=d")

        case .google:
            if let latitude, let longitude {
                open("comgooglemaps://?daddr=\(latitude),\(longitude)&directionsmode=driving")
            } else {
                open("comgooglemaps://?daddr=\(query)&directionsmode=driving")
            }

        case .yandexMaps:
            if let latitude, let longitude {
                open("yandexmaps://maps.yandex.com/?rtext=~\(latitude),\(longitude)&rtt=auto")
            } else {
                open("yandexmaps://maps.yandex.com/?text=\(query)")
            }

        case .yandexNavi:
            if let latitude, let longitude {
                open("yandexnavi://build_route_on_map?lat_to=\(latitude)&lon_to=\(longitude)")
            } else {
                open("yandexnavi://map_search?text=\(query)")
            }

        case .waze:
            if let latitude, let longitude {
                open("waze://?ll=\(latitude),\(longitude)&navigate=yes")
            } else {
                open("waze://?q=\(query)&navigate=yes")
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }
}


/// Harita uygulaması seçim kartı.
struct MapAppPicker: View {

    let pharmacy: Pharmacy
    let apps: [MapApp]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(apps) { app in
                        Button {
                            app.openRoute(to: pharmacy)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {

                                MapAppIcon(app: app)

                                Text(app.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(pharmacy.name)
                } footer: {
                    Text("Yalnızca telefonunda kurulu olan uygulamalar listelenir.")
                }
            }
            .navigationTitle("Yol tarifi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Vazgeç") { dismiss() }
                }
            }
        }
    }
}


/// Assets içinde logo varsa onu, yoksa simgeyi gösterir.
struct MapAppIcon: View {

    let app: MapApp

    var body: some View {
        Group {
            if UIImage(named: app.assetName) != nil {
                Image(app.assetName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: app.systemImage)
                    .font(.title3)
                    .foregroundStyle(app.tint)
                    .frame(width: 34, height: 34)
                    .background(app.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: 34, height: 34)
    }
}
