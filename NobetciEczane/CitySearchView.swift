import SwiftUI
import MapKit
import UIKit

/// Türkiye geneli manuel arama.
/// Konum izni olmasa da, başka bir şehre bakmak isteyen kullanıcı için.
/// İl listesi (gövde). Kendi NavigationStack'i yoktur; sarmalayan ekran sağlar.
struct ProvinceListView: View {

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
        .navigationTitle("İller")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// Konumdan bulunan il/ilçe ile açılan ekran.
/// Konum çözülemediyse doğrudan il listesi gösterilir.
struct DetectedPlaceSheet: View {

    let province: Province?
    let district: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let province {
                    DistrictListView(
                        province: province,
                        highlightedDistrict: district
                    )
                } else {
                    ProvinceListView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("Diğer iller") {
                        ProvinceListView()
                    }
                }
            }
        }
    }
}


/// Seçilen ilin ilçeleri. Liste uygulamaya gömülü değildir,
/// il sayfasındaki bağlantılardan canlı okunur.
struct DistrictListView: View {

    let province: Province

    /// Konumdan bulunan ilçe. Verilirse listenin en üstünde işaretlenir.
    var highlightedDistrict: String? = nil

    @State private var districts: [District] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let service = DutyPharmacyService()

    var body: some View {
        List {
            if let highlightedDistrict,
               !highlightedDistrict.isEmpty {

                Section("Konumunuz") {
                    NavigationLink {
                        DutyListView(
                            citySlug: province.slug,
                            districtSlug: service.slug(highlightedDistrict),
                            title: highlightedDistrict,
                            subtitle: province.name
                        )
                    } label: {
                        Label(
                            "\(province.name) · \(highlightedDistrict)",
                            systemImage: "location.fill"
                        )
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                    }
                }
            }

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
                        PharmacyRow(
                            pharmacy: pharmacy,
                            distanceText: distanceText(for: pharmacy)
                        )
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

    @State private var showMapPicker = false

    /// Telefonda kurulu harita uygulamaları.
    private var mapApps: [MapApp] { MapApp.installed }

    var body: some View {
        HStack(spacing: 12) {

            // --- Gövde: her yerine dokunulunca haritada yol tarifi açılır ---
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

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { route() }

            // --- Sağ kolon: yol tarifi ve arama butonları ---
            VStack(spacing: 8) {

                Button(action: route) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .frame(width: 40, height: 34)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Yol tarifi")

                if let phone = pharmacy.phone,
                   !PharmacyRow.dialDigits(phone).isEmpty {

                    Button {
                        PharmacyRow.call(phone)
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .frame(width: 40, height: 34)
                            .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(pharmacy.name) eczanesini ara")
                }
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showMapPicker) {
            MapAppPicker(pharmacy: pharmacy, apps: mapApps)
                .presentationDetents([.medium, .large])
        }
    }


    /// Tek harita uygulaması varsa doğrudan açar,
    /// birden fazlaysa kullanıcıya seçenek sunar.
    private func route() {

        let apps = mapApps

        if apps.count <= 1 {
            (apps.first ?? .apple).openRoute(to: pharmacy)
            return
        }

        showMapPicker = true
    }


    /// "0 (232) 832-35-32" -> "02328323532"
    static func dialDigits(_ phone: String) -> String {
        phone.filter { $0.isNumber }
    }


    static func call(_ phone: String) {

        let digits = dialDigits(phone)

        guard digits.count >= 7,
              let url = URL(string: "tel://\(digits)"),
              UIApplication.shared.canOpenURL(url)
        else { return }

        UIApplication.shared.open(url)
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
