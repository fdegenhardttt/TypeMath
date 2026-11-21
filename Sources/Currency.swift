import Foundation

/// Exchange rates from the European Central Bank (via frankfurter.dev), refreshed daily and cached.
enum Currency {
    /// Units of each currency per 1 EUR.
    static var rates: [String: Double] = UserDefaults.standard.dictionary(forKey: ratesKey) as? [String: Double] ?? [:]

    private static let ratesKey = "currencyRates"
    private static let fetchedKey = "currencyRatesFetched"
    private static let url = URL(string: "https://api.frankfurter.dev/v1/latest")!

    /// Fetches fresh rates if the cached ones are missing or older than 12 hours.
    static func refreshIfNeeded() {
        if let fetched = UserDefaults.standard.object(forKey: fetchedKey) as? Date,
           Date().timeIntervalSince(fetched) < 12 * 3600, !rates.isEmpty { return }

        struct Response: Decodable { let rates: [String: Double] }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
            var fresh = response.rates
            fresh["EUR"] = 1
            DispatchQueue.main.async {
                rates = fresh
                UserDefaults.standard.set(fresh, forKey: ratesKey)
                UserDefaults.standard.set(Date(), forKey: fetchedKey)
            }
        }.resume()
    }

    static func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let fromRate = rates[from], let toRate = rates[to] else { return nil }
        return amount / fromRate * toRate
    }

    static let symbols: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₺", "₪", "₱", "฿"]

    /// The ISO code for a currency written as a code, symbol or name ("usd", "$", "dollars").
    static func code(for name: String) -> String? {
        let key = name.lowercased()
        if let code = names[key] { return code }
        let upper = name.uppercased()
        return upper.count == 3 && rates[upper] != nil ? upper : nil
    }

    private static let names: [String: String] = {
        var table = [String: String]()
        func add(_ code: String, _ names: String) {
            for name in names.split(separator: " ") { table[String(name)] = code }
        }
        add("USD", "$ dollar dollars bucks")
        add("EUR", "€ euro euros")
        add("GBP", "£ pound pounds quid sterling")
        add("JPY", "¥ yen")
        add("CNY", "yuan rmb renminbi")
        add("CHF", "franc francs")
        add("INR", "₹ rupee rupees")
        add("KRW", "₩ won")
        add("TRY", "₺ lira")
        add("ILS", "₪ shekel shekels")
        add("PHP", "₱")
        add("MXN", "peso pesos")
        add("THB", "฿ baht")
        add("BRL", "real reais")
        add("SEK", "krona kronor")
        add("NOK", "krone kroner")
        add("PLN", "zloty zlotys")
        add("HUF", "forint forints")
        add("CZK", "koruna")
        add("ZAR", "rand")
        return table
    }()
}
