import SwiftUI
import MapKit
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationManager = LocationManager()
    @State private var pharmacies: [Pharmacy] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var showPlaceSheet = false
    @State private var detectedCity: String?
    @State private var detectedDistrict: String?

    private let service = DutyPharmacyService()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.03, green: 0.10, blue: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if hasSearched && !pharmacies.isEmpty {
                resultsView
            } else {
                homeView
            }
        }
        .task {
            // Uygulama her açıldığında cihazdan güncel konum istenir.
            await refreshLocationOnEntry()
        }
        .onChange(of: scenePhase) { phase in
            // Arka plandan tekrar uygulamaya gelindiğinde de konumu tazele.
            if phase == .active {
                Task { await refreshLocationOnEntry() }
            }
        }
        .alert(
            "Bilgi",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showPlaceSheet) {
            DetectedPlaceSheet(
                province: detectedProvince,
                district: detectedDistrict
            )
        }
    }

    private var homeView: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Text("NÖBETÇİ")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                Text("Eczane Bul")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Button(action: search) {
                ZStack {
                    Circle().fill(.green.opacity(0.12)).frame(width: 235, height: 235)
                    Circle().stroke(.green.opacity(0.30), lineWidth: 2).frame(width: 205, height: 205)
                    Circle().fill(.green.gradient).frame(width: 165, height: 165)
                        .shadow(color: .green.opacity(0.55), radius: 35)

                    if isLoading {
                        ProgressView().tint(.white).scaleEffect(1.6)
                    } else {
                        Image(systemName: "cross.case.fill")
                            .font(.system(size: 58, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .disabled(isLoading)
            .accessibilityLabel("Yakındaki nöbetçi eczaneleri bul")

            Text(isLoading ? "Nöbetçi eczaneler aranıyor…" : "Bulmak için dokun")
                .font(.headline)
                .foregroundStyle(.secondary)

            Button {
                showPlaceSheet = true
            } label: {
                HStack(spacing: 8) {

                    Image(systemName: detectedCity == nil
                          ? "location.magnifyingglass"
                          : "location.fill")

                    Text(placeLabel)

                    if detectedCity != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .opacity(0.6)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(detectedCity == nil ? Color.secondary : Color.green)
                .padding(.vertical, 11)
                .padding(.horizontal, 20)
                .background(
                    (detectedCity == nil ? Color.gray : Color.green).opacity(0.12),
                    in: Capsule()
                )
            }
            .disabled(detectedCity == nil)
            .accessibilityLabel("Bulunduğunuz konum: \(placeLabel)")

            Spacer()

            Text("Konumunuz yalnızca yakındaki nöbetçi eczaneleri bulmak için kullanılır.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
                .padding(.bottom, 18)
        }
        .padding()
    }

    private var resultsView: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pharmacies) { pharmacy in
                        PharmacyRow(
                            pharmacy: pharmacy,
                            distanceText: formattedDistance(pharmacy),
                            onRoute: { openMaps(pharmacy) }
                        )
                    }
                } header: {
                    Text("En yakından en uzağa · \(pharmacies.count) nöbetçi eczane")
                }
            }
            .navigationTitle("Nöbetçi Eczaneler")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Yenile", action: search).disabled(isLoading)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        pharmacies = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    /// Konum rozetinde gösterilecek metin.
    private var placeLabel: String {

        guard let detectedCity else {
            return "Konum belirleniyor…"
        }

        if let detectedDistrict, !detectedDistrict.isEmpty {
            return "\(detectedCity) · \(detectedDistrict)"
        }

        return detectedCity
    }

    /// Konumdan bulunan ili 81 il listesiyle eşleştirir.
    private var detectedProvince: Province? {

        guard let detectedCity else { return nil }

        let needle = PharmacyText.normalize(detectedCity)

        return TurkeyProvinces.all.first {
            PharmacyText.normalize($0.name) == needle || $0.slug == needle
        }
    }

    private func refreshLocationOnEntry() async {
        do {
            let location = try await locationManager.refreshCurrentLocation()

            // Uygulama açılır açılmaz il ve ilçe işaretlenir.
            if let place = await service.detectPlace(for: location) {
                detectedCity = place.city
                detectedDistrict = place.district
            }
        } catch LocationError.requestAlreadyInProgress {
            // .task ve scenePhase aynı anda tetiklenirse ikinci isteği sessizce geç.
        } catch LocationError.permissionDenied {
            // İzin mesajını kullanıcı arama butonuna bastığında da görecek.
            // Açılışta arka arkaya uyarı göstermiyoruz.
        } catch {
            // Geçici GPS hatası aramayı engellemez; butona basınca yeniden denenir.
        }
    }

    private func search() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Butona her basıldığında da eski koordinatı kullanmak yerine yeniden ölç.
                let location = try await locationManager.requestCurrentLocation()
                let found = try await service.fetchNearest(to: location)

                await MainActor.run {
                    pharmacies = found
                    hasSearched = true
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func formattedDistance(_ pharmacy: Pharmacy) -> String? {
        guard let location = locationManager.location,
              let distance = pharmacy.distance(from: location) else {
            return nil
        }

        if distance < 1000 {
            return "\(Int(distance.rounded())) m"
        }
        return String(format: "%.1f km", distance / 1000)
    }

    private func openMaps(_ pharmacy: Pharmacy) {
        if let lat = pharmacy.latitude, let lon = pharmacy.longitude {
            let item = MKMapItem(
                placemark: MKPlacemark(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                )
            )
            item.name = pharmacy.name
            item.openInMaps(
                launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
            )
            return
        }

        let query = (pharmacy.name + " " + pharmacy.address)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let url = URL(string: "http://maps.apple.com/?daddr=\(query)&dirflg=d") {
            UIApplication.shared.open(url)
        }
    }
}
