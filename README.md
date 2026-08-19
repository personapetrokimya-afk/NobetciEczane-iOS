# Nöbetçi Eczane iOS

Sunucu/veritabanı gerektirmeyen SwiftUI iPhone uygulaması.

## Özellikler
- Tek büyük buton ile arama
- iPhone konumu
- Yalnızca nöbetçi eczane listesi
- Mesafeye göre sıralama (koordinat mevcutsa)
- Dokununca Apple Haritalar'da araç rotası
- Üyelik / giriş / kendi sunucusu yok

## GitHub ile IPA
1. Bu klasörün içeriğini yeni GitHub reposunun köküne yükleyin.
2. `main` branch'e gönderin.
3. GitHub > Actions > Build iOS IPA açın.
4. Workflow bittikten sonra Artifacts bölümünden `NobetciEczane-unsigned-ipa` indirin.
5. IPA unsigned'dır; Sideloadly/AltStore veya Apple Developer imzası ile kurulmalıdır.

## Veri kaynağı hakkında önemli not
Uygulama güncel nöbetçi eczaneleri kendi sunucusundan değil, iPhone'dan doğrudan `eczaneler.gen.tr` şehir sayfasından okumaya çalışır. Bu üçüncü taraf sitenin HTML yapısı veya erişim politikası değişirse `DutyPharmacyService.swift` içindeki provider'ın güncellenmesi gerekir.

App Store için üretime çıkmadan önce resmi/lisanslı ve stabil bir veri kaynağına geçmek önerilir.

---

## v2 — "Nöbetçi eczane bilgisine şu anda ulaşılamıyor" düzeltmesi

Bu mesaj `ServiceError.sourceUnavailable` hatasıdır ve sadece iki durumda çıkar:
istek hiç tamamlanamadı (ağ/TLS hatası) ya da sunucu 2xx dışında bir kod döndü.
Eski kodda her iki durum da tek bir genel cümleye indirgendiği için sebebi görmek mümkün değildi.

`DutyPharmacyService.swift` yeniden yazıldı:

1. **İlçe sayfası öncelikli.** Önce `/nobetci-<il>-<ilce>` (ör. `nobetci-izmir-bornova`),
   başarısız olursa `/nobetci-<il>` denenir. Böylece il sayfasını indirip regex ile ilçe
   süzmeye gerek kalmaz.
2. **Yeniden deneme ve alternatif host.** Her adres için 2 deneme, ardından `www`'suz varyant.
   404 alınırsa boşuna beklenmez, bir sonraki adaya geçilir.
3. **Sadece BUGÜNÜN nöbeti.** Kaynak sayfa 3 günlük liste yayınlıyor. Eski parser üç tabloyu
   birden okuduğu için yarının ve öbür günün eczaneleri de listeye giriyordu. Artık ilk tablo
   (bugünkü nöbet) kesilip yalnızca o işleniyor.
4. **Tablo tabanlı parser.** Site `<tr>/<td>` yapısı kullanıyor: 1. hücre eczane adı,
   2. hücre adres + "Yol Tarifi" bağlantısı (koordinat buradan çıkıyor), 3. hücre telefon.
   Eski genel blok/regex yöntemi yedek olarak duruyor.
5. **Anlamlı hata mesajı.** Artık HTTP kodu veya `URLError` numarası kullanıcıya gösterilir:
   `Teknik detay: HTTP 403 — www.eczaneler.gen.tr` gibi. Sorun tekrarlarsa nedeni bu satırdan okunur.
6. **İlçede nöbetçi yoksa uygulama hata vermiyor**, il genelindeki en yakın nöbetçilere düşüyor.
7. **Geocoder sınırlandı.** Koordinatı olmayan en fazla 10 kayıt için adres çözümlemesi yapılıyor.
   Eskiden 100+ kayıt için tek tek istek atıldığından Apple hız sınırına takılıp uygulama
   dakikalarca "yükleniyor" durumunda kalabiliyordu.
8. `waitsForConnectivity = false` — ağ yokken 30 saniye bekleyip donmak yerine anında hata.

`Info.plist`:
- **`CFBundleExecutable` eklendi.** Sideloadly'deki
  `Guru Meditation ... could not find executable ... %%1\%%1.app` hatasının sebebi buydu:
  `GENERATE_INFOPLIST_FILE = NO` olduğu için Xcode bu anahtarı kendisi eklemiyor, plist'te de
  yoktu; imzalayıcı hangi dosyanın çalıştırılabilir olduğunu bulamıyordu.
- `NSAppTransportSecurity` istisnası eklendi (üçüncü taraf site TLS/yönlendirme sorunlarına karşı).

Build:
- `build-ios.yml` **`.github/workflows/` altına taşındı**. Repo kökünde durduğu için
  GitHub Actions workflow'u hiç çalıştırmıyordu.
- Workflow'a `CFBundleExecutable` doğrulama adımı eklendi; binary yoksa build kırmızıya düşer,
  bozuk IPA üretilmez.

### Sorun devam ederse
Hata kutusundaki "Teknik detay" satırına bakın:

| Detay | Anlamı | Yapılacak |
|---|---|---|
| `HTTP 403` / `HTTP 503` | Site isteği bot sanıp engelliyor | Kaynağı değiştirmek gerekir |
| `HTTP 404` | İl/ilçe slug'ı sitede yok | `slug()` eşlemesine istisna ekleyin |
| `-1009` | Cihaz internete bağlı değil | Bağlantıyı kontrol edin |
| `-1001` | Zaman aşımı | Tekrar deneyin |
| `listede kayıt yok` | Sayfa geldi ama HTML yapısı değişmiş | Parser güncellenmeli |
