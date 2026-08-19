import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()
    @State private var pharmacies: [Pharmacy] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasSearched = false

    private let service = DutyPharmacyService()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.03, green: 0.10, blue: 0.09)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if hasSearched && !pharmacies.isEmpty {
                resultsView
            } else {
                homeView
            }
        }
        .alert("Bilgi", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Tamam", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
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
            Spacer()
            Text("Konumunuz yalnızca yakındaki nöbetçi eczaneleri bulmak için kullanılır.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 34)
                .padding(.bottom, 18)
        }
        .padding()
    }

    private var resultsView: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(pharmacies) { pharmacy in
                        Button { openMaps(pharmacy) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "cross.case.fill")
                                    .font(.title2).foregroundStyle(.green)
                                    .frame(width: 42, height: 42)
                                    .background(.green.opacity(0.12), in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pharmacy.name).font(.headline).foregroundStyle(.primary)
                                    Text(pharmacy.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if let distance = formattedDistance(pharmacy) {
                                        Text(distance).font(.caption.weight(.semibold)).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                } header: {
                    Text("En yakındaki nöbetçi eczaneler")
                }
            }
            .navigationTitle("Nöbetçi Eczaneler")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Yenile", action: search).disabled(isLoading)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { pharmacies = []; hasSearched = false } label: { Image(systemName: "xmark") }
                }
            }
        }
    }

    private func search() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
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
        guard let location = locationManager.location, let d = pharmacy.distance(from: location) else { return nil }
        if d < 1000 { return "\(Int(d.rounded())) m" }
        return String(format: "%.1f km", d / 1000)
    }

    private func openMaps(_ pharmacy: Pharmacy) {
        if let lat = pharmacy.latitude, let lon = pharmacy.longitude {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
            item.name = pharmacy.name
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            return
        }

        let query = (pharmacy.name + " " + pharmacy.address).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?daddr=\(query)&dirflg=d") {
            UIApplication.shared.open(url)
        }
    }
}
