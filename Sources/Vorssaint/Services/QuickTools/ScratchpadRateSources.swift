// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// One day's table as a source published it: units of each currency per US
/// dollar, already limited to the currencies calculation mode understands.
struct ScratchpadRateTable: Equatable, Sendable {
    /// The newest date among the rates kept.
    let date: String
    let rates: [String: Double]

    /// A rate older than this, against the newest in the same table, is left
    /// out so a later source can fill the currency instead. Central banks
    /// publish on business days, so a few days of lag is normal.
    static let maximumLagDays = 7

    static func make(_ rows: [(symbol: String, rate: Double, date: String)]) -> ScratchpadRateTable? {
        let supported = ScratchpadCurrency.supportedSymbols
        var dayNumbers: [String: Int] = [:]
        var kept: [(symbol: String, rate: Double, date: String, day: Int)] = []
        for row in rows {
            let symbol = row.symbol.uppercased()
            guard supported.contains(symbol.lowercased()), row.rate.isFinite, row.rate > 0 else { continue }
            let day: Int
            if let known = dayNumbers[row.date] { day = known } else {
                guard ScratchpadExchangeRateParser.validDate(row.date), let number = dayNumber(row.date) else { continue }
                dayNumbers[row.date] = number
                day = number
            }
            kept.append((symbol, row.rate, row.date, day))
        }
        guard let newest = kept.max(by: { $0.day < $1.day }) else { return nil }
        var rates: [String: Double] = [:]
        var rateDays: [String: Int] = [:]
        for row in kept where newest.day - row.day <= maximumLagDays {
            // A currency listed twice keeps its newest rate, whatever the order.
            if let existing = rateDays[row.symbol], existing >= row.day { continue }
            rates[row.symbol] = row.rate
            rateDays[row.symbol] = row.day
        }
        return ScratchpadRateTable(date: newest.date, rates: rates)
    }

    /// Days since 1970-01-01 for a validated `yyyy-MM-dd` date.
    private static func dayNumber(_ date: String) -> Int? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let (year, month, day) = (parts[0], parts[1], parts[2])
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// Decodes what it can and turns anything else into nil, so one malformed row
/// does not discard a whole table.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// The built-in places rates can come from. Each is one documented public
/// endpoint that needs no key, asked for a table against US dollars. A source
/// is only contacted when the person has it switched on, and a later source
/// is only asked when the ones before it did not return every currency.
enum ScratchpadRateProvider: String, CaseIterable, Sendable {
    /// The European Central Bank's own reference rates, about thirty
    /// currencies, served by Frankfurter.
    case ecb
    /// Frankfurter's blend of rates from many central banks and official
    /// sources: far more currencies than the ECB publishes, a few tenths of a
    /// percent away from its figures on the ones both have.
    case frankfurter
    case fawazahmed0

    var displayName: String {
        switch self {
        case .ecb: return "ECB (via Frankfurter)"
        case .frankfurter: return "Frankfurter (central banks)"
        case .fawazahmed0: return "Currency API (fawazahmed0)"
        }
    }

    /// The first two share one host. The third is another host, so it is
    /// contacted only after the person asks for it.
    var enabledByDefault: Bool { self != .fawazahmed0 }

    /// Endpoints in the order they are tried; each after the first is a
    /// mirror of the same data on another host.
    var requests: [URLRequest] {
        switch self {
        case .ecb, .frankfurter:
            var components = URLComponents(string: self == .ecb
                                           ? "https://api.frankfurter.dev/v2/providers/ecb/rates"
                                           : "https://api.frankfurter.dev/v2/rates")!
            let symbols = ScratchpadCurrency.supportedSymbols
                .subtracting([ScratchpadExchangeRateParser.expectedBase.lowercased()])
                .map { $0.uppercased() }
                .sorted()
                .joined(separator: ",")
            components.queryItems = [
                URLQueryItem(name: "base", value: ScratchpadExchangeRateParser.expectedBase),
                URLQueryItem(name: "quotes", value: symbols),
            ]
            return [Self.get(components.url!)]
        case .fawazahmed0:
            // The Pages copy is refreshed first; the CDN copy can trail it by a day.
            return [
                "https://latest.currency-api.pages.dev/v1/currencies/usd.json",
                "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json",
            ].map { Self.get(URL(string: $0)!) }
        }
    }

    private static func get(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        return request
    }

    /// The checked table in a response, or nil when it is not one.
    func table(from data: Data) -> ScratchpadRateTable? {
        switch self {
        case .ecb, .frankfurter:
            struct Row: Decodable { let date: String; let base: String; let quote: String; let rate: Double }
            guard let rows = try? JSONDecoder().decode([Lossy<Row>].self, from: data) else { return nil }
            return ScratchpadRateTable.make(rows.compactMap(\.value)
                .filter { $0.base.uppercased() == ScratchpadExchangeRateParser.expectedBase }
                .map { ($0.quote, $0.rate, $0.date) })
        case .fawazahmed0:
            struct Payload: Decodable { let date: String; let usd: [String: Lossy<Double>] }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
            return ScratchpadRateTable.make(payload.usd.compactMap { key, rate in
                rate.value.map { (key, $0, payload.date) }
            })
        }
    }
}

enum ScratchpadRateMerge {
    /// Tables in priority order: each currency comes from the first table that
    /// has it, and the date is the newest among the tables that contributed.
    static func merged(_ tables: [ScratchpadRateTable]) -> ScratchpadCurrencyRates? {
        var rates: [String: Double] = [:]
        var newest = ""
        for table in tables {
            var contributed = false
            for (symbol, rate) in table.rates where rates[symbol] == nil {
                rates[symbol] = rate
                contributed = true
            }
            if contributed { newest = max(newest, table.date) }
        }
        guard !rates.isEmpty else { return nil }
        return ScratchpadCurrencyRates(date: newest, base: ScratchpadExchangeRateParser.expectedBase, rates: rates)
    }

    /// The supported currencies none of the tables has, which is what decides
    /// whether the next source is worth asking.
    static func missing(from tables: [ScratchpadRateTable]) -> Set<String> {
        var missing = Set(ScratchpadCurrency.supportedSymbols.map { $0.uppercased() })
        missing.remove(ScratchpadExchangeRateParser.expectedBase)
        for table in tables { missing.subtract(table.rates.keys) }
        return missing
    }
}

struct ScratchpadRateSourceChoice: Equatable, Sendable {
    let provider: ScratchpadRateProvider
    var isEnabled: Bool
}

/// The person's order and on/off choice for each source, kept as one short
/// string such as `frankfurter:1,fawazahmed0:0`.
enum ScratchpadRateSources {
    static func choices(from raw: String?) -> [ScratchpadRateSourceChoice] {
        var result: [ScratchpadRateSourceChoice] = []
        for entry in (raw ?? "").split(separator: ",") {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard let provider = parts.first.flatMap({ ScratchpadRateProvider(rawValue: String($0)) }),
                  !result.contains(where: { $0.provider == provider }) else { continue }
            result.append(.init(provider: provider, isEnabled: parts.dropFirst().first != "0"))
        }
        // A source added in a later version joins at the end, in its default state.
        for provider in ScratchpadRateProvider.allCases where !result.contains(where: { $0.provider == provider }) {
            result.append(.init(provider: provider, isEnabled: provider.enabledByDefault))
        }
        // At least one source stays on, or the daily update could never fetch anything.
        if !result.contains(where: \.isEnabled) { result[0].isEnabled = true }
        return result
    }

    static func encoded(_ choices: [ScratchpadRateSourceChoice]) -> String {
        choices.map { "\($0.provider.rawValue):\($0.isEnabled ? 1 : 0)" }.joined(separator: ",")
    }

    static func enabledProviders(from raw: String?) -> [ScratchpadRateProvider] {
        choices(from: raw).filter(\.isEnabled).map(\.provider)
    }

    /// Turns a source on or off. The last source on cannot be turned off.
    static func setting(_ provider: ScratchpadRateProvider, enabled: Bool,
                        in choices: [ScratchpadRateSourceChoice]) -> [ScratchpadRateSourceChoice] {
        guard let index = choices.firstIndex(where: { $0.provider == provider }) else { return choices }
        var next = choices
        next[index].isEnabled = enabled
        return next.contains(where: \.isEnabled) ? next : choices
    }

    /// Moves a source up (negative) or down (positive) the priority list.
    static func moving(_ provider: ScratchpadRateProvider, by offset: Int,
                       in choices: [ScratchpadRateSourceChoice]) -> [ScratchpadRateSourceChoice] {
        guard let index = choices.firstIndex(where: { $0.provider == provider }),
              choices.indices.contains(index + offset) else { return choices }
        var next = choices
        next.insert(next.remove(at: index), at: index + offset)
        return next
    }
}
