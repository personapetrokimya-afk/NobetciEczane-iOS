import Foundation

/// eczaneler.gen.tr adres yapısına uygun 81 il.
/// `slug`, `https://www.eczaneler.gen.tr/nobetci-<slug>` adresinde kullanılır.
struct Province: Identifiable, Hashable {

    var id: String { slug }

    let name: String
    let slug: String
}


enum TurkeyProvinces {

    static let all: [Province] = [
        Province(name: "Adana", slug: "adana"),
        Province(name: "Adıyaman", slug: "adiyaman"),
        Province(name: "Afyonkarahisar", slug: "afyonkarahisar"),
        Province(name: "Ağrı", slug: "agri"),
        Province(name: "Aksaray", slug: "aksaray"),
        Province(name: "Amasya", slug: "amasya"),
        Province(name: "Ankara", slug: "ankara"),
        Province(name: "Antalya", slug: "antalya"),
        Province(name: "Ardahan", slug: "ardahan"),
        Province(name: "Artvin", slug: "artvin"),
        Province(name: "Aydın", slug: "aydin"),
        Province(name: "Balıkesir", slug: "balikesir"),
        Province(name: "Bartın", slug: "bartin"),
        Province(name: "Batman", slug: "batman"),
        Province(name: "Bayburt", slug: "bayburt"),
        Province(name: "Bilecik", slug: "bilecik"),
        Province(name: "Bingöl", slug: "bingol"),
        Province(name: "Bitlis", slug: "bitlis"),
        Province(name: "Bolu", slug: "bolu"),
        Province(name: "Burdur", slug: "burdur"),
        Province(name: "Bursa", slug: "bursa"),
        Province(name: "Çanakkale", slug: "canakkale"),
        Province(name: "Çankırı", slug: "cankiri"),
        Province(name: "Çorum", slug: "corum"),
        Province(name: "Denizli", slug: "denizli"),
        Province(name: "Diyarbakır", slug: "diyarbakir"),
        Province(name: "Düzce", slug: "duzce"),
        Province(name: "Edirne", slug: "edirne"),
        Province(name: "Elazığ", slug: "elazig"),
        Province(name: "Erzincan", slug: "erzincan"),
        Province(name: "Erzurum", slug: "erzurum"),
        Province(name: "Eskişehir", slug: "eskisehir"),
        Province(name: "Gaziantep", slug: "gaziantep"),
        Province(name: "Giresun", slug: "giresun"),
        Province(name: "Gümüşhane", slug: "gumushane"),
        Province(name: "Hakkâri", slug: "hakkari"),
        Province(name: "Hatay", slug: "hatay"),
        Province(name: "Iğdır", slug: "igdir"),
        Province(name: "Isparta", slug: "isparta"),
        Province(name: "İstanbul", slug: "istanbul"),
        Province(name: "İzmir", slug: "izmir"),
        Province(name: "Kahramanmaraş", slug: "kahramanmaras"),
        Province(name: "Karabük", slug: "karabuk"),
        Province(name: "Karaman", slug: "karaman"),
        Province(name: "Kars", slug: "kars"),
        Province(name: "Kastamonu", slug: "kastamonu"),
        Province(name: "Kayseri", slug: "kayseri"),
        Province(name: "Kilis", slug: "kilis"),
        Province(name: "Kırıkkale", slug: "kirikkale"),
        Province(name: "Kırklareli", slug: "kirklareli"),
        Province(name: "Kırşehir", slug: "kirsehir"),
        Province(name: "Kocaeli", slug: "kocaeli"),
        Province(name: "Konya", slug: "konya"),
        Province(name: "Kütahya", slug: "kutahya"),
        Province(name: "Malatya", slug: "malatya"),
        Province(name: "Manisa", slug: "manisa"),
        Province(name: "Mardin", slug: "mardin"),
        Province(name: "Mersin", slug: "mersin"),
        Province(name: "Muğla", slug: "mugla"),
        Province(name: "Muş", slug: "mus"),
        Province(name: "Nevşehir", slug: "nevsehir"),
        Province(name: "Niğde", slug: "nigde"),
        Province(name: "Ordu", slug: "ordu"),
        Province(name: "Osmaniye", slug: "osmaniye"),
        Province(name: "Rize", slug: "rize"),
        Province(name: "Sakarya", slug: "sakarya"),
        Province(name: "Samsun", slug: "samsun"),
        Province(name: "Siirt", slug: "siirt"),
        Province(name: "Sinop", slug: "sinop"),
        Province(name: "Sivas", slug: "sivas"),
        Province(name: "Şanlıurfa", slug: "sanliurfa"),
        Province(name: "Şırnak", slug: "sirnak"),
        Province(name: "Tekirdağ", slug: "tekirdag"),
        Province(name: "Tokat", slug: "tokat"),
        Province(name: "Trabzon", slug: "trabzon"),
        Province(name: "Tunceli", slug: "tunceli"),
        Province(name: "Uşak", slug: "usak"),
        Province(name: "Van", slug: "van"),
        Province(name: "Yalova", slug: "yalova"),
        Province(name: "Yozgat", slug: "yozgat"),
        Province(name: "Zonguldak", slug: "zonguldak")
    ]
}


/// Bir ilin ilçesi. Liste uygulamaya gömülmez, il sayfasından canlı okunur.
struct District: Identifiable, Hashable {

    var id: String { slug }

    let name: String
    let slug: String
}
