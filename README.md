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
