import SwiftUI
import MapKit
import UIKit
import Combine

struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationManager = LocationManager()

    /// Bugün NÖBETÇİ olan eczaneler.
    @State private var dutyPharmacies: [Pharmacy] = []

    /// Nöbetçi olmayan ama ŞU AN açık olan yakın eczaneler.
    @State private var openPharmacies: [Pharmacy] = []

    @State private var phase: SearchPhase = .idle

    enum SearchPhase {
        case idle       // bekliyor
        case locating   // telefon konumu ölçülüyor
        case searching  // nöbetçi eczaneler çekiliyor
    }

    private var isLoading: Bool { phase != .idle }

    @State private var errorMessage: String?
    @State private var dutyNote: String?
    @State private var hasSearched = false
    @State private var showPlaceSheet = false
    @State private var detectedCity: String?
    @State private var detectedDistrict: String?

    private let service = DutyPharmacyService.shared
    private let nearbyFinder = NearbyOpenPharmacyFinder()

    /// Liste ekranda dururken saat ilerler. Bu değer dakikada bir tazelenir ve
    /// süzgeçleri yeniden çalıştırır: 19:00'da kapanan eczane 19:00'da listeden düşer.
    @State private var now = Date()
    @State private var lastSearch: Date?

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Nöbeti hâlâ süren kayıtlar.
    private var visibleDuty: [Pharmacy] {
        dutyPharmacies.filter {
            PharmacyHours.isDutyStillActive(endsAt: $0.dutyEndsAt, now: now)
        }
    }

    /// Mesaisi hâlâ süren kayıtlar. Mesai bittiyse bölüm tamamen kaybolur.
    private var visibleOpen: [Pharmacy] {

        guard PharmacyHours.isOpenNow(now) else { return [] }

        return openPharmacies.filter { pharmacy in

            guard let closesAt = pharmacy.closesAt else { return true }

            let margin = Double(PharmacyHours.closingSafetyMinutes * 60)

            return now < closesAt.addingTimeInterval(-margin)
        }
    }

    private var hasResults: Bool {
        !visibleDuty.isEmpty || !visibleOpen.isEmpty
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.03, green: 0.10, blue: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if hasSearched && hasResults {
                resultsView
            } else {
                homeView
            }
        }
        .task {
            // Uygulama her açıldığında cihazdan güncel konum istenir.
            await refreshLocationOnEntry()
        }
        .onReceive(clock) { tick in
            now = tick
        }
        .onChange(of: scenePhase) { newScenePhase in
            // Arka plandan tekrar uygulamaya gelindiğinde konumu ve saati tazele.
            if newScenePhase == .active {
                now = Date()
                Task { await refreshLocationOnEntry() }

                // Ekrandaki liste bayatladıysa (5 dk) sessizce yenile:
                // saat 09:00'ı geçmişse nöbet devretmiş olabilir.
                if hasSearched,
                   let lastSearch,
                   Date().timeIntervalSince(lastSearch) > 300 {
                    search()
                }
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
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            .padding(.bottom, 18)
        }
        .padding()
    }


    // MARK: - Sonuç listesi (iki başlık)

    private var resultsView: some View {
        NavigationStack {
            List {

                // 1) NÖBETÇİLER — yalnızca o gün nöbetçi olanlar.
                Section {
                    if visibleDuty.isEmpty {
                        Text(dutyNote ?? "Bu bölge için bugünün nöbet listesi alınamadı.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleDuty) { pharmacy in
                            PharmacyRow(
                                pharmacy: pharmacy,
                                distanceText: formattedDistance(pharmacy)
                            )
                        }
                    }
                } header: {
                    Label(
                        visibleDuty.isEmpty
                            ? "Nöbetçiler"
                            : "Nöbetçiler · \(visibleDuty.count)",
                        systemImage: "moon.stars.fill"
                    )
                } footer: {
                    if !visibleDuty.isEmpty {
                        Text("Bugünün resmî nöbet listesi. Gece de açıktır.")
                    }
                }

                // 2) ŞU AN AÇIK OLAN ECZANELER — mesai içindeyse gösterilir.
                if !visibleOpen.isEmpty {
                    Section {
                        ForEach(visibleOpen) { pharmacy in
                            PharmacyRow(
                                pharmacy: pharmacy,
                                distanceText: formattedDistance(pharmacy)
                            )
                        }
                    } header: {
                        Label(
                            "Şu an açık eczaneler · \(visibleOpen.count)",
                            systemImage: "sun.max.fill"
                        )
                    } footer: {
                        Text(openNowFooter)
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("Kapalı eczaneler listelenmez. Türkiye saati: "
                             + PharmacyHours.timeText(now))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Eczaneler")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Yenile", action: search).disabled(isLoading)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dutyPharmacies = []
                        openPharmacies = []
                        dutyNote = nil
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }


    private var openNowFooter: String {

        guard let closing = PharmacyHours.closingDate(Date()) else {
            return "Nöbetçi olmayan, normal mesaisiyle açık eczaneler."
        }

        return "Nöbetçi değiller; standart mesai bitiminde "
            + "(\(PharmacyHours.timeText(closing))) kapanırlar. "
            + "Yola çıkmadan aramanız iyi olur."
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

    @MainActor
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
        } catch {
            // Geçici GPS hatası aramayı engellemez; butona basınca yeniden denenir.
        }
    }

    private var statusText: String {
        switch phase {
        case .idle:      return "Bulmak için dokun"
        case .locating:  return "Konumunuz bulunuyor…"
        case .searching: return "Açık eczaneler aranıyor…"
        }
    }


    // MARK: - Arama

    private func search() {

        guard phase == .idle else { return }

        errorMessage = nil
        dutyNote = nil

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

                // 1) Bugünün nöbetçileri.
                var duty: [Pharmacy] = []
                var note: String?

                do {
                    duty = try await service.fetchNearest(to: location)
                } catch {
                    note = error.localizedDescription
                }

                // 2) Mesai içindeyse yakındaki AÇIK eczaneler.
                let open = await nearbyFinder.openNow(
                    around: location,
                    excluding: duty
                )

                await MainActor.run {

                    dutyPharmacies = duty
                    openPharmacies = open
                    dutyNote = note
                    phase = .idle
                    now = Date()
                    lastSearch = Date()

                    if duty.isEmpty && open.isEmpty {
                        errorMessage = note
                            ?? "Şu anda açık eczane bulunamadı. Birazdan tekrar dene."
                        hasSearched = false
                    } else {
                        hasSearched = true
                    }
                }

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .idle
                }
            }
        }
    }

    @MainActor
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
}
