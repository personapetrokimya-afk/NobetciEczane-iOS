import Foundation

/// Türkiye saatine (Europe/Istanbul) göre "bu eczane ŞU AN açık mı?" hesabı.
///
/// Uygulamanın altın kuralı: **kapalı bir eczane listede görünmez.**
///
/// İki farklı açıklık türü vardır:
/// - **Nöbetçi eczane:** nöbet penceresi (akşamdan ertesi sabaha, pazar/tatilde gün boyu)
///   içinde 24 saat açıktır.
/// - **Normal eczane:** yalnızca mesai saatlerinde açıktır. Pazar ve resmî tatillerde
///   normal eczaneler kapalıdır; o saatlerde yalnızca nöbetçiler listelenir.
enum PharmacyHours {

    // MARK: - Ayarlar

    /// Nöbet her sabah bu saatte devredilir (TEB uygulaması: 09:00).
    static let handoverHour = 9

    /// Kapanışa bu kadar dakikadan az kaldıysa eczane artık "açık" sayılmaz.
    /// Kullanıcı kapanmak üzere olan bir eczaneye boşuna gitmesin diye güvenlik payı.
    static let closingSafetyMinutes = 5

    /// Kapanışa bu süreden az kaldıysa satırda "kapanıyor" uyarısı gösterilir.
    static let closingSoonMinutes = 45

    /// Standart eczane mesaisi (dakika, gün başından itibaren).
    /// Hafta içi 09:00–19:00, cumartesi 09:00–13:30.
    /// Oda kararlarına göre il il değişebildiği için tek yerde tutulur.
    private static let weekdayWindow = Window(open: 9 * 60, close: 19 * 60)
    private static let saturdayWindow = Window(open: 9 * 60, close: 13 * 60 + 30)


    // MARK: - Takvim

    static var timeZone: TimeZone {
        TimeZone(identifier: "Europe/Istanbul") ?? .current
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "tr_TR")
        return calendar
    }


    // MARK: - Mesai penceresi

    struct Window {
        /// Gün başından itibaren dakika.
        let open: Int
        let close: Int
    }

    /// Yarım gün (arife, 28 Ekim) kapanışı.
    private static let halfDayClose = 13 * 60

    /// O gün normal eczanelerin mesaisi. Kapalı günlerde `nil`.
    static func window(on date: Date) -> Window? {

        if isHoliday(date) { return nil }

        let base: Window?

        switch calendar.component(.weekday, from: date) {
        case 1:  base = nil              // Pazar: yalnızca nöbetçiler
        case 7:  base = saturdayWindow   // Cumartesi
        default: base = weekdayWindow    // Pazartesi–Cuma
        }

        guard let base else { return nil }

        // Arife ve 28 Ekim yarım gündür: erken kapanışı hesaba kat.
        guard isHalfDay(date) else { return base }

        return Window(open: base.open, close: min(base.close, halfDayClose))
    }


    /// Normal (nöbetçi olmayan) eczaneler şu anda açık mı?
    static func isOpenNow(_ now: Date = Date()) -> Bool {

        guard let window = window(on: now) else { return false }

        let minute = minutesSinceMidnight(now)

        return minute >= window.open
            && minute <= window.close - closingSafetyMinutes
    }


    /// Bugünün kapanış anı (normal mesai). Kapalı günlerde `nil`.
    static func closingDate(_ now: Date = Date()) -> Date? {

        guard let window = window(on: now) else { return nil }

        return calendar.date(
            bySettingHour: window.close / 60,
            minute: window.close % 60,
            second: 0,
            of: now
        )
    }


    /// Kapanışa kalan dakika. Kapalıysa `nil`.
    static func minutesUntilClosing(_ now: Date = Date()) -> Int? {

        guard let closing = closingDate(now) else { return nil }

        let minutes = Int(closing.timeIntervalSince(now) / 60)

        return minutes >= 0 ? minutes : nil
    }


    // MARK: - Nöbet penceresi

    /// Şu an geçerli olan nöbet gününün tarihi.
    /// Sabah devir saatinden ÖNCE hâlâ dün akşam başlayan nöbet geçerlidir.
    static func currentDutyDate(_ now: Date = Date()) -> Date {

        let hour = calendar.component(.hour, from: now)

        guard hour < handoverHour else { return now }

        return calendar.date(byAdding: .day, value: -1, to: now) ?? now
    }


    /// Bir nöbet gününün bitiş anı: ERTESİ SABAH devir saati.
    /// ("22 Ağustos gününden 23 Ağustos sabahına kadar" → 23 Ağustos 09:00)
    static func dutyEnd(forDutyDate date: Date) -> Date? {

        guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
            return nil
        }

        return calendar.date(
            bySettingHour: handoverHour,
            minute: 0,
            second: 0,
            of: next
        )
    }


    /// Nöbet hâlâ sürüyor mu? (Geçmiş güne ait liste asla gösterilmez.)
    static func isDutyStillActive(endsAt: Date?, now: Date = Date()) -> Bool {

        guard let endsAt else { return true }   // Bitiş bilinmiyorsa engelleme.

        return now < endsAt
    }


    // MARK: - Resmî tatiller

    /// Resmî tatilde normal eczaneler kapalıdır (yalnızca nöbetçiler açıktır).
    static func isHoliday(_ date: Date) -> Bool {

        let parts = calendar.dateComponents([.year, .month, .day], from: date)

        guard let year = parts.year,
              let month = parts.month,
              let day = parts.day else { return false }

        let key = "\(month)-\(day)"

        if fixedHolidays.contains(key) { return true }

        return religiousHolidays[year]?.contains(key) ?? false
    }

    /// Her yıl sabit resmî tatiller.
    private static let fixedHolidays: Set<String> = [
        "1-1",    // Yılbaşı
        "4-23",   // Ulusal Egemenlik ve Çocuk Bayramı
        "5-1",    // Emek ve Dayanışma Günü
        "5-19",   // Atatürk'ü Anma, Gençlik ve Spor Bayramı
        "7-15",   // Demokrasi ve Millî Birlik Günü
        "8-30",   // Zafer Bayramı
        "10-29"   // Cumhuriyet Bayramı
    ]

    /// Dinî bayramlar (Ramazan / Kurban) — Diyanet takvimi.
    /// Yeni yıllar için bu tablonun güncellenmesi yeterlidir.
    private static let religiousHolidays: [Int: Set<String>] = [
        2026: ["3-20", "3-21", "3-22",
               "5-27", "5-28", "5-29", "5-30"],
        2027: ["3-10", "3-11", "3-12",
               "5-17", "5-18", "5-19", "5-20"],
        2028: ["2-27", "2-28", "2-29",
               "5-5", "5-6", "5-7", "5-8"],
        2029: ["2-15", "2-16", "2-17",
               "4-24", "4-25", "4-26", "4-27"],
        2030: ["2-5", "2-6", "2-7",
               "4-13", "4-14", "4-15", "4-16"]
    ]


    /// Yarım gün: bayram arifeleri ve 28 Ekim.
    static func isHalfDay(_ date: Date) -> Bool {

        let parts = calendar.dateComponents([.year, .month, .day], from: date)

        guard let year = parts.year,
              let month = parts.month,
              let day = parts.day else { return false }

        let key = "\(month)-\(day)"

        if key == "10-28" { return true }

        return halfDays[year]?.contains(key) ?? false
    }

    /// Dinî bayram arifeleri (öğleden sonra tatil).
    private static let halfDays: [Int: Set<String>] = [
        2026: ["3-19", "5-26"],
        2027: ["3-9", "5-16"],
        2028: ["2-26", "5-4"],
        2029: ["2-14", "4-23"],
        2030: ["2-4", "4-12"]
    ]


    // MARK: - Yardımcılar

    static func minutesSinceMidnight(_ date: Date) -> Int {

        let parts = calendar.dateComponents([.hour, .minute], from: date)

        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }


    /// "19:00" biçiminde Türkiye saati.
    static func timeText(_ date: Date) -> String {

        let formatter = DateFormatter()

        formatter.locale = Locale(identifier: "tr_TR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"

        return formatter.string(from: date)
    }


    /// Bitiş anı bugün mü yarın mı olduğunu da belirten metin:
    /// "yarın 09:00'a kadar açık" / "19:00'a kadar açık".
    static func untilText(_ date: Date, now: Date = Date()) -> String {

        let sameDay = calendar.isDate(date, inSameDayAs: now)

        return sameDay
            ? "\(timeText(date))'a kadar açık"
            : "yarın \(timeText(date))'a kadar açık"
    }
}
