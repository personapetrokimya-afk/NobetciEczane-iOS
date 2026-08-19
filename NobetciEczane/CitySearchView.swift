import SwiftUI
import MapKit
import UIKit

/// Türkiye geneli manuel arama.
/// Konum izni olmasa da, başka bir şehre bakmak isteyen kullanıcı için.
struct CitySearchView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var filtered: [Province] {

        let needle = PharmacyText.normalize(query)

        guard !needle.isEmpty else {
            return TurkeyProvinces.all
        }

        return TurkeyProvinces.all.filter {
            PharmacyText.normalize($0.name).contains(needle)
                || $0.slug.contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    Text("Eşleşen il bulunamadı.")
                        .foregroundStyle(.secondary)
                }

                ForEach(filtered) { province in
                    NavigationLink {
                        DistrictListView(province: province)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "building.2.fill")
                                .foregroundStyle(.green)
                            Text(province.name)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "İl ara"
            )
            .navigationTitle("Şehir Seç")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
}


/// Seçilen ilin ilçeleri. Liste uygulamaya gömülü değildir,
/// il sayfasındaki bağlantılardan canlı okunur.
struct DistrictListView: View {

    let province: Province

    @State private var districts: [District] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let service = DutyPharmacyService()

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DutyListView(
                        citySlug: province.slug,
                        districtSlug: nil,
                        title: province.name,
                        subtitle: "İl geneli"
                    )
                } label: {
                    Label("Tüm \(province.name)", systemImage: "list.bullet")
                        .fontWeight(.semibold)
                }
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("İlçeler yükleniyor…")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !districts.isEmpty {
                Section("İlçeler") {
                    ForEach(districts) { district in
                        NavigationLink {
                            DutyListView(
                                citySlug: province.slug,
                                districtSlug: district.slug,
                                title: district.name,
                                subtitle: province.name
                            )
                        } label: {
                            Text(district.name)
                        }
                    }
                }
            }
        }
        .navigationTitle(province.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private func load() async {

        guard districts.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            districts = try await service.fetchDistricts(citySlug: province.slug)
        } catch {
            errorMessage = "İlçe listesi alınamadı. İl geneli aramayı kullanabilirsin.\n(\(error.localizedDescription))"
        }

        isLoading = false
    }
}


/// Seçilen il/ilçe için bugünkü nöbetçi eczaneler.
struct DutyListView: View {

    let citySlug: String
    let districtSlug: String?
    let title: String
    let subtitle: String

    @StateObject private var locationManager = LocationManager()

    @State private var pharmacies: [Pharmacy] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let service = DutyPharmacyService()

    var body: some View {
        List {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Nöbetçi eczaneler aranıyor…")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Text(errorMessage)
                        .font(.callout)

                    Button("Tekrar dene") {
                        Task { await load(force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding(.vertical, 6)
            }

            if !pharmacies.isEmpty {
                Section {
                    ForEach(pharmacies) { pharmacy in
                        Button {
                            openMaps(pharmacy)
                        } label: {
                            PharmacyRow(
                                pharmacy: pharmacy,
                                distanceText: distanceText(for: pharmacy)
                            )
                        }
                    }
                } header: {
                    Text("\(subtitle) · bugün nöbetçi \(pharmacies.count) eczane")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load(force: false)
        }
    }

    private func load(force: Bool) async {

        if !force, !pharmacies.isEmpty { return }

        isLoading = true
        errorMessage = nil

        do {
            var found = try await service.fetchDuty(
                citySlug: citySlug,
                districtSlug: districtSlug,
                districtName: districtSlug == nil ? nil : title
            )

            // Konum verilebiliyorsa burada da en yakından en uzağa sırala.
            if let location = try? await locationManager.requestCurrentLocation() {
                found.sort {
                    ($0.distance(from: location) ?? .greatestFiniteMagnitude)
                        < ($1.distance(from: location) ?? .greatestFiniteMagnitude)
                }
            }

            pharmacies = found

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func distanceText(for pharmacy: Pharmacy) -> String? {

        guard let location = locationManager.location,
              let distance = pharmacy.distance(from: location) else {
            return nil
        }

        if distance < 1000 {
            return "\(Int(distance)) m"
        }

        return String(format: "%.1f km", distance / 1000)
    }

    private func openMaps(_ pharmacy: Pharmacy) {

        if let lat = pharmacy.latitude,
           let lon = pharmacy.longitude {

            let item = MKMapItem(
                placemark: MKPlacemark(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                )
            )

            item.name = pharmacy.name
            item.openInMaps(
                launchOptions: [
                    MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
                ]
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


struct PharmacyRow: View {

    let pharmacy: Pharmacy
    let distanceText: String?

    var body: some View {
        HStack(spacing: 14) {

            Image(systemName: "cross.case.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 38, height: 38)
                .background(.green.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {

                Text(pharmacy.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                if !pharmacy.address.isEmpty {
                    Text(pharmacy.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {

                    if let distanceText {
                        Text(distanceText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    if let phone = pharmacy.phone {
                        Text(phone)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if pharmacy.isCrossVerified {
                        Label(
                            "\(pharmacy.sources.count) kaynak",
                            systemImage: "checkmark.seal.fill"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}


/// Türkçe karakterleri de doğru eşleyen basit metin normalizasyonu.
enum PharmacyText {

    static func normalize(_ value: String) -> String {

        var output = value.lowercased(with: Locale(identifier: "tr_TR"))

        let replacements: [(String, String)] = [
            ("i\u{0307}", "i"), ("ı", "i"), ("ç", "c"), ("ğ", "g"),
            ("ö", "o"), ("ş", "s"), ("ü", "u"), ("â", "a")
        ]

        for (source, target) in replacements {
            output = output.replacingOccurrences(of: source, with: target)
        }

        output = output.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "tr_TR")
        )

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
