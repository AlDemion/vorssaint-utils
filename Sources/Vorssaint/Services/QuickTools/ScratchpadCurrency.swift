// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Exchange rates for calculation mode. The date is the rate provider's own
/// calendar date, not the day the download happened, so a weekend rate still
/// reads as Friday. An empty date marks the copy that ships with the app.
struct ScratchpadCurrencyRates: Codable, Equatable, Sendable {
    let date: String
    let base: String
    let rates: [String: Double]

    /// A fallback so a calculation line still answers without a network
    /// connection: rates to 4 significant digits from 29 Oct 2026, covering
    /// every supported currency. Deliberately labelled as built in rather
    /// than presented as today's market, and never dated.
    static let bundled = ScratchpadCurrencyRates(
        date: "",
        base: "USD",
        rates: [
            "AED": 3.672, "AFN": 65.04, "ALL": 81.46, "AMD": 359.7,
            "ANG": 1.79, "AOA": 917.9, "ARS": 1538, "AUD": 1.422,
            "AWG": 1.79, "AZN": 1.699, "BAM": 1.753, "BBD": 2.029,
            "BDT": 124, "BHD": 0.376, "BIF": 3007, "BMD": 1,
            "BND": 1.282, "BOB": 12.01, "BRL": 5.343, "BSD": 1.008,
            "BTN": 95.17, "BWP": 13.54, "BYN": 2.958, "BZD": 2.026,
            "CAD": 1.403, "CDF": 2293, "CHF": 0.829, "CLP": 984,
            "CNY": 6.665, "COP": 3154, "CRC": 453.9, "CVE": 98.85,
            "CZK": 21.86, "DJF": 177.6, "DKK": 6.708, "DOP": 61.28,
            "DZD": 135.3, "EGP": 56.11, "ERN": 15.17, "ETB": 161.5,
            "EUR": 0.8964, "FJD": 2.242, "FKP": 0.7511, "GBP": 0.7512,
            "GEL": 2.592, "GHS": 11.61, "GIP": 0.7601, "GMD": 73.51,
            "GNF": 8820, "GTQ": 7.643, "GYD": 211.7, "HKD": 7.851,
            "HNL": 26.86, "HTG": 131, "HUF": 329.4, "IDR": 18_160,
            "ILS": 3.093, "INR": 95.17, "IQD": 1514, "IRR": 1_858_000,
            "ISK": 122.2, "JMD": 158.3, "JOD": 0.709, "JPY": 157.9,
            "KES": 129.8, "KGS": 87.46, "KHR": 4082, "KMF": 442.3,
            "KPW": 130, "KRW": 1334, "KWD": 0.3094, "KYD": 0.8372,
            "KZT": 455.9, "LAK": 22_330, "LBP": 89_670, "LKR": 332,
            "LRD": 170.2, "LSL": 16.64, "LYD": 6.431, "MAD": 9.855,
            "MDL": 18.01, "MGA": 4578, "MKD": 55.33, "MMK": 2098,
            "MNT": 3597, "MOP": 8.086, "MRU": 40.28, "MUR": 47.48,
            "MVR": 15.44, "MWK": 1733, "MXN": 18.65, "MYR": 4.079,
            "MZN": 63.72, "NAD": 16.64, "NGN": 1346, "NIO": 36.62,
            "NOK": 9.306, "NPR": 152.4, "NZD": 1.772, "OMR": 0.3845,
            "PAB": 1, "PEN": 3.449, "PGK": 4.485, "PHP": 63.97,
            "PKR": 277.4, "PLN": 3.954, "PYG": 5843, "QAR": 3.64,
            "RON": 4.803, "RSD": 105.6, "RUB": 80.56, "RWF": 1477,
            "SAR": 3.75, "SBD": 8.009, "SCR": 14.45, "SDG": 600.1,
            "SEK": 9.934, "SGD": 1.282, "SHP": 0.7511, "SLE": 22.86,
            "SOS": 571.5, "SRD": 37.66, "SSP": 5760, "STN": 21.88,
            "SVC": 8.752, "SYP": 122, "SZL": 16.63, "THB": 33.77,
            "TJS": 9.207, "TMT": 3.5, "TND": 3.008, "TOP": 2.381,
            "TRY": 49.82, "TTD": 6.753, "TWD": 32.46, "TZS": 2640,
            "UAH": 45.57, "UGX": 4389, "UYU": 40.19, "UZS": 11_960,
            "VES": 885.2, "VND": 25_800, "VUV": 118.9, "WST": 2.734,
            "XAF": 588, "XAG": 0.01871, "XAU": 0.000248, "XCD": 2.739,
            "XCG": 1.796, "XDR": 0.739, "XOF": 588, "XPD": 0.0009814,
            "XPF": 107.2, "XPT": 0.0006573, "YER": 236.1, "ZAR": 16.62,
            "ZMW": 20.22, "ZWG": 26.76,
        ])

    var isBundled: Bool {
        date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Converts through the provider's base currency, so both directions work
    /// even though the response does not repeat the base in its rate table.
    func convert(value: Double, from: String, to: String) -> Double? {
        guard value.isFinite else { return nil }
        let source = from.uppercased()
        let target = to.uppercased()
        let base = base.uppercased()
        guard source == base || isUsableRate(rates[source]),
              target == base || isUsableRate(rates[target]) else { return nil }
        let inBase = source == base ? value : value / rates[source]!
        let converted = target == base ? inBase : inBase * rates[target]!
        return converted.isFinite ? converted : nil
    }

    /// The provider's date written the way this Mac writes dates. Nil for the
    /// built-in table, which has no honest date to show.
    func localizedDate(locale: Locale) -> String? {
        guard !isBundled else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        guard let parsed = parser.date(from: date) else { return date }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: parsed)
    }

    private func isUsableRate(_ rate: Double?) -> Bool {
        guard let rate else { return false }
        return rate.isFinite && rate > 0
    }
}

enum ScratchpadCurrency {
    /// The ISO 4217 currencies a rate source can quote, as lowercase parser
    /// vocabulary; the UI only ever shows the uppercased ISO code. CUP is left
    /// out on purpose: "cup" is already a unit of volume. Sources also publish
    /// crypto and non-ISO codes, which are ignored.
    static let supportedSymbols: Set<String> = [
        "aed", "afn", "all", "amd", "ang", "aoa", "ars", "aud", "awg", "azn",
        "bam", "bbd", "bdt", "bhd", "bif", "bmd", "bnd", "bob", "brl", "bsd",
        "btn", "bwp", "byn", "bzd", "cad", "cdf", "chf", "clp", "cny", "cop",
        "crc", "cve", "czk", "djf", "dkk", "dop", "dzd", "egp", "ern", "etb",
        "eur", "fjd", "fkp", "gbp", "gel", "ghs", "gip", "gmd", "gnf", "gtq",
        "gyd", "hkd", "hnl", "htg", "huf", "idr", "ils", "inr", "iqd", "irr",
        "isk", "jmd", "jod", "jpy", "kes", "kgs", "khr", "kmf", "kpw", "krw",
        "kwd", "kyd", "kzt", "lak", "lbp", "lkr", "lrd", "lsl", "lyd", "mad",
        "mdl", "mga", "mkd", "mmk", "mnt", "mop", "mru", "mur", "mvr", "mwk",
        "mxn", "myr", "mzn", "nad", "ngn", "nio", "nok", "npr", "nzd", "omr",
        "pab", "pen", "pgk", "php", "pkr", "pln", "pyg", "qar", "ron", "rsd",
        "rub", "rwf", "sar", "sbd", "scr", "sdg", "sek", "sgd", "shp", "sle",
        "sos", "srd", "ssp", "stn", "svc", "syp", "szl", "thb", "tjs", "tmt",
        "tnd", "top", "try", "ttd", "twd", "tzs", "uah", "ugx", "usd", "uyu",
        "uzs", "ves", "vnd", "vuv", "wst", "xaf", "xag", "xau", "xcd", "xcg",
        "xdr", "xof", "xpd", "xpf", "xpt", "yer", "zar", "zmw", "zwg",
    ]

    static func convert(_ input: String, rates: ScratchpadCurrencyRates,
                        decimalSeparator: String = Locale.current.decimalSeparator ?? ".",
                        groupingSeparator: String = Locale.current.groupingSeparator ?? ",",
                        locale: Locale = .current) -> (value: Double, formatted: String)? {
        let tokens = input.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 4, tokens[2] == "to",
              supportedSymbols.contains(tokens[1]), supportedSymbols.contains(tokens[3]),
              let value = number(tokens[0], decimalSeparator: decimalSeparator,
                                 groupingSeparator: groupingSeparator),
              let converted = rates.convert(value: value, from: tokens[1], to: tokens[3]),
              converted.isFinite else { return nil }
        return (converted, format(converted, in: tokens[3], locale: locale))
    }

    static func format(_ value: Double, in symbol: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = zeroDecimalCurrencies.contains(symbol.lowercased()) ? 0 : 2
        let formatted = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(formatted) \(symbol.uppercased())"
    }

    /// Currencies conventionally written without a fractional part, so a yen
    /// answer does not read as "1,234.00 JPY".
    private static let zeroDecimalCurrencies: Set<String> = [
        "bif", "clp", "djf", "gnf", "huf", "idr", "isk", "jpy", "kmf", "krw",
        "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf",
    ]

    private static func number(_ input: String, decimalSeparator: String,
                               groupingSeparator: String) -> Double? {
        var normalized = input
        if !groupingSeparator.isEmpty, groupingSeparator != decimalSeparator {
            normalized = normalized.replacingOccurrences(of: groupingSeparator, with: "")
        }
        if decimalSeparator != "." {
            normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
        }
        guard !normalized.isEmpty, normalized.filter({ $0 == "." }).count <= 1,
              normalized.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return Double(normalized)
    }
}
