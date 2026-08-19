import SwiftUI
import MapKit
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationManager = LocationManager()
    @State private var pharmacies: [Pharmacy] = []
    @State private var phase: SearchPhase = .idle

    enum SearchPhase {
        case idle       // bekliyor
        case locating   // telefon konumu ölçülüyor
        case searching  // nöbetçi eczaneler çekiliyor
    }

    private var isLoading: Bool { phase != .idle }
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
        .onChange(of: scenePhase) { newScenePhase in
            // Arka plandan tekrar uygulamaya gelindiğinde de konumu tazele.
            if newScenePhase == .active {
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

            Text(statusText)
                .font(.headline)
                .foregroundStyle(phase == .locating ? Color.green : Color.secondary)
                .animation(.easeInOut(duration: 0.2), value: phase)

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

            VStack(spacing: 6) {

                Text("Konumunuz yalnızca yakındaki nöbetçi eczaneleri bulmak için kullanılır.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)

                Text("Developed by D.Y.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
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
                            distanceText: formattedDistance(pharmacy)
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

    private var statusText: String {
        switch phase {
        case .idle:      return "Bulmak için dokun"
        case .locating:  return "Konumunuz bulunuyor…"
        case .searching: return "Nöbetçi eczaneler aranıyor…"
        }
    }

    private func search() {

        guard phase == .idle else { return }

        errorMessage = nil

        // Önce konum. Konum tam olarak gelmeden arama BAŞLAMAZ.
        phase = .locating

        Task {
            do {
                let location = try await locationManager.requestCurrentLocation()

                // Konum yeni geldiyse il/ilçe rozetini de tazele.
                if let place = await service.detectPlace(for: location) {
                    await MainActor.run {
                        detectedCity = place.city
                        detectedDistrict = place.district
                    }
                }

                await MainActor.run { phase = .searching }

                let found = try await service.fetchNearest(to: location)

                await MainActor.run {
                    pharmacies = found
                    hasSearched = true
                    phase = .idle
                }

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .idle
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
