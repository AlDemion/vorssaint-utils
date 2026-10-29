// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation

enum ScratchpadExchangeRateTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let payload = """
    [{"date":"2026-10-25","base":"USD","quote":"EUR","rate":0.9},
     {"date":"2026-10-25","base":"USD","quote":"PLN","rate":4.0},
     {"date":"2026-10-25","base":"USD","quote":"JPY","rate":150},
     {"date":"2026-10-25","base":"USD","quote":"XYZ","rate":2.0}]
    """

    /// A Frankfurter-shaped response that quotes every supported currency.
    private static func fullPayload(date: String = "2026-10-25") -> String {
        let rows = ScratchpadCurrency.supportedSymbols.subtracting(["usd"]).sorted().map {
            #"{"date":"\#(date)","base":"USD","quote":"\#($0.uppercased())","rate":1.5}"#
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    static func run(_ suite: TestSuite) {
        parser(suite)
        rateSources(suite)
        calculationSyntax(suite)
        primeNotation(suite)
        cache(suite)
        redirects(suite)
        downloads(suite)
        service(suite)
        currency(suite)
        evaluatorLines(suite)
        editorLayout(suite)
        accessibleAnswers(suite)
        typedCalculations(suite)
    }

    private static func typedCalculations(_ suite: TestSuite) {
        let rates = ScratchpadCurrencyRates(date: "2026-10-25", base: "USD", rates: ["EUR": 0.9, "PLN": 4])
        func evaluate(_ source: String) -> ScratchpadCalculationEvaluator.Result {
            ScratchpadCalculationEvaluator.evaluate(source, currencyRates: rates,
                decimalSeparator: ".", groupingSeparator: ",", locale: Locale(identifier: "en_US"))
        }
        let rent = evaluate("rent = 900 eur\ntotal = rent * 3\ntotal to usd")
        suite.expect(rent.lines.map(\.value) == [900, 2700, 3000]
                     && rent.lines[1].formatted?.hasSuffix("EUR") == true,
                     "money variables retain their currency through arithmetic and conversion")
        let units = evaluate("10 km + 5 mi\n(1 km + 1 mi) to m\n1 km / 500 m")
        suite.expect(abs((units.lines[0].value ?? 0) - 18.04672) < 0.00001
                     && abs((units.lines[1].value ?? 0) - 2609.344) < 0.00001
                     && units.lines[2].value == 2,
                     "compatible unit arithmetic converts values and ratios become scalars")
        suite.expect(evaluate("20 eur + 50 pln").lines[0].value == 31.25,
                     "money arithmetic converts the right operand to the left currency")
        let mixed = evaluate("1 km to m\n1 usd to eur\nsum\navg\nprev")
        suite.expect(mixed.lines[2].value == nil && mixed.lines[3].value == nil
                     && mixed.lines[4].formatted?.hasSuffix("EUR") == true,
                     "aggregates reject incompatible dimensions while prev retains its unit")
        let aggregate = evaluate("1 km\n1000 m\nsum")
        suite.expect(aggregate.lines[2].value == 2 && aggregate.lines[2].formatted?.contains("km") == true,
                     "compatible aggregates retain their measurement unit")
        suite.expect(evaluate("100 usd to eur =").lines[0].value == 90,
                     "currency conversions accept the same trailing equals as arithmetic")
        suite.expect(evaluate("2 km * 3 km\n10 / 0\n5 eur + 2 km\n(2 eur + 3 eur").lines.allSatisfy { $0.value == nil },
                     "unsupported derived dimensions, invalid syntax and division by zero never invent an answer")
        suite.expect(evaluate("a = 10\nb = 20\nsum\navg\n\nc = 5\nsum").lines.map(\.value)
                     == [10, 20, 30, 15, nil, 5, 5],
                     "aggregate answers do not compound and blank lines start a new section")
        suite.expect(evaluate("10\n20\ntotal\naverage\ntotal = 7\ntotal").lines.map(\.value)
                     == [10, 20, 30, 15, 7, 7], "aggregate aliases respect explicit variables")
        suite.expect(evaluate("per person: 90 / 3").lines[0].value == 30,
                     "a label prefix leaves its expression calculable")
        let percentages = evaluate("rent = 900 eur\n20% of rent\nrent + 10%\nrent - 20%\nrent + (5% + 5%)")
        suite.expect(percentages.lines.map(\.value) == [900, 180, 990, 720, nil],
                     "unit quantities retain relative percentage semantics without adding bare scalars")
        suite.expect(abs((evaluate("5 ft 11 in to cm").lines[0].value ?? 0) - 180.34) < 0.0001,
                     "compound feet and inches convert through the shared unit parser")
        suite.expect(abs((evaluate("56/7 floz in ml").lines[0].value ?? 0) - 236.5882365) < 0.001,
                     "a calculated source amount retains its unit before conversion")
        let negative = evaluate("x = -2\nx^2\na = -2 km\na * 3")
        suite.expect(negative.lines.map(\.value) == [-2, 4, -2, -6], "signed scalar and unit variables preserve precedence")
    }

    private static func snapshot(date: String = "2026-10-25",
                                 fetchedAt: Date = now,
                                 rates: [String: Double] = ["EUR": 0.9, "PLN": 4.0],
                                 sources: String? = "frankfurter") -> ScratchpadExchangeRateSnapshot {
        ScratchpadExchangeRateSnapshot(
            rates: ScratchpadCurrencyRates(date: date, base: "USD", rates: rates),
            fetchedAt: fetchedAt, sources: sources)
    }

    private static func parser(_ suite: TestSuite) {
        let mixed = """
        [{"date":"2026-10-25","base":"USD","quote":"EUR","rate":0.9},
         {"date":"2026-10-25","base":"USD","quote":"UAH","rate":45.5},
         {"date":"2026-10-24","base":"USD","quote":"JPY","rate":150},
         {"date":"2026-10-25","base":"USD","quote":"BTC","rate":0.00001},
         {"date":"2026-10-25","base":"USD","quote":"XYZ","rate":2.0},
         {"date":"2026-10-10","base":"USD","quote":"AED","rate":3.6725},
         {"date":"2026-10-25","base":"EUR","quote":"GBP","rate":0.88},
         {"date":"2026-10-25","base":"USD","quote":"CHF","rate":null},
         {"date":"2026-10-25","base":"USD","quote":"SEK","rate":0}]
        """
        let table = ScratchpadRateProvider.frankfurter.table(from: Data(mixed.utf8))
        suite.expect(table?.rates == ["EUR": 0.9, "UAH": 45.5, "JPY": 150],
                     "Frankfurter rows keep supported currencies against USD and drop crypto, unknown codes, other bases, null and zero rates")
        suite.expect(table?.date == "2026-10-25",
                     "a table is dated by its newest rate, and a rate more than a week older is left for another source")

        let twice = #"[{"date":"2026-10-24","base":"USD","quote":"EUR","rate":0.8},{"date":"2026-10-25","base":"USD","quote":"EUR","rate":0.9},{"date":"2026-10-24","base":"USD","quote":"EUR","rate":0.7}]"#
        suite.expect(ScratchpadRateProvider.frankfurter.table(from: Data(twice.utf8))?.rates["EUR"] == 0.9,
                     "a currency listed twice keeps its newest rate whatever the order")

        let impossible = #"[{"date":"2026-02-30","base":"USD","quote":"EUR","rate":0.9},{"date":"yesterday","base":"USD","quote":"PLN","rate":4}]"#
        suite.expect(ScratchpadRateProvider.frankfurter.table(from: Data(impossible.utf8)) == nil,
                     "rows with an impossible rate date fail the response")
        suite.expect(ScratchpadRateProvider.frankfurter.table(from: Data("[]".utf8)) == nil
                     && ScratchpadRateProvider.frankfurter.table(from: Data("not json".utf8)) == nil,
                     "an empty or malformed response is rejected")

        let fawaz = #"{"date":"2026-10-25","usd":{"eur":0.91,"uah":45.6,"aed":3.67,"btc":0.00001,"chf":null,"sek":0}}"#
        let fawazTable = ScratchpadRateProvider.fawazahmed0.table(from: Data(fawaz.utf8))
        suite.expect(fawazTable?.rates == ["EUR": 0.91, "UAH": 45.6, "AED": 3.67] && fawazTable?.date == "2026-10-25",
                     "the second source reads its own shape the same way")
        suite.expect(ScratchpadRateProvider.fawazahmed0.table(from: Data(#"{"usd":{"eur":1}}"#.utf8)) == nil,
                     "a response without a date is rejected")
    }

    private static func rateSources(_ suite: TestSuite) {
        // Merging: each currency comes from the first source that has it.
        let first = ScratchpadRateTable(date: "2026-10-25", rates: ["EUR": 0.9, "PLN": 4.0])
        let second = ScratchpadRateTable(date: "2026-10-26", rates: ["EUR": 0.91, "UAH": 45.6])
        let merged = ScratchpadRateMerge.merged([first, second])
        suite.expect(merged?.rates == ["EUR": 0.9, "PLN": 4.0, "UAH": 45.6],
                     "a currency comes from the highest-priority source that has it")
        suite.expect(merged?.date == "2026-10-26",
                     "the table date is the newest among the sources that contributed")
        let redundant = ScratchpadRateMerge.merged([first, ScratchpadRateTable(date: "2026-10-30", rates: ["EUR": 1])])
        suite.expect(redundant?.date == "2026-10-25",
                     "a source that adds nothing does not change the date")
        suite.expect(ScratchpadRateMerge.merged([]) == nil, "no tables, no merged table")
        suite.expect(ScratchpadRateMerge.missing(from: [first]).contains("UAH")
                     && !ScratchpadRateMerge.missing(from: [first]).contains("EUR")
                     && !ScratchpadRateMerge.missing(from: [first]).contains("USD"),
                     "missing currencies exclude the base and what a table already has")

        // Supported currencies, collisions and the built-in table.
        suite.expect(ScratchpadCurrency.supportedSymbols.allSatisfy { CommandBarUnits.family(of: $0) == nil },
                     "no supported currency code is also a unit symbol")
        suite.expect(ScratchpadCurrency.supportedSymbols.contains("uah") && ScratchpadCurrency.supportedSymbols.contains("aed")
                     && !ScratchpadCurrency.supportedSymbols.contains("cup"),
                     "the supported set is wide and leaves out the code that is also a unit")
        let uncovered = ScratchpadCurrency.supportedSymbols.subtracting(["usd"])
            .filter { ScratchpadCurrencyRates.bundled.rates[$0.uppercased()] == nil }
        suite.expect(uncovered.isEmpty, "the built-in table covers every supported currency: \(uncovered.sorted())")
        let english = Locale(identifier: "en_US")
        suite.expect(ScratchpadCurrency.format(1234, in: "vnd", locale: english) == "1,234 VND"
                     && ScratchpadCurrency.format(1234.5, in: "uah", locale: english) == "1,234.5 UAH",
                     "zero-decimal currencies are written without cents")

        // The person's order and on/off choice.
        let defaults = ScratchpadRateSources.choices(from: nil)
        suite.expect(defaults.map(\.provider) == [.ecb, .frankfurter, .fawazahmed0] && defaults.map(\.isEnabled) == [true, true, false],
                     "out of the box the two same-host sources are on and the other host is off")
        let custom = ScratchpadRateSources.choices(from: "fawazahmed0:1,frankfurter:1")
        suite.expect(custom.map(\.provider) == [.fawazahmed0, .frankfurter, .ecb] && custom.first?.isEnabled == true,
                     "a saved order is kept and a missing source joins the end")
        suite.expect(ScratchpadRateSources.choices(from: "bogus:1,frankfurter:0,frankfurter:1").map(\.provider)
                     == [.frankfurter, .ecb, .fawazahmed0],
                     "unknown and repeated entries are dropped and a missing source is appended")
        suite.expect(ScratchpadRateSources.choices(from: "ecb:0,frankfurter:0,fawazahmed0:0").first?.isEnabled == true,
                     "a saved choice that turns every source off keeps the first on")
        let onlyOne = ScratchpadRateSources.choices(from: "ecb:0,frankfurter:1,fawazahmed0:0")
        suite.expect(ScratchpadRateSources.setting(.frankfurter, enabled: false, in: onlyOne) == onlyOne,
                     "the last source on cannot be turned off")
        let all = ScratchpadRateSources.setting(.fawazahmed0, enabled: true, in: defaults)
        suite.expect(ScratchpadRateSources.enabledProviders(from: ScratchpadRateSources.encoded(all)) == [.ecb, .frankfurter, .fawazahmed0],
                     "a choice survives being written and read back")
        suite.expect(ScratchpadRateSources.moving(.fawazahmed0, by: -1, in: all).map(\.provider) == [.ecb, .fawazahmed0, .frankfurter]
                     && ScratchpadRateSources.moving(.ecb, by: -1, in: all) == all
                     && ScratchpadRateSources.moving(.fawazahmed0, by: 1, in: all) == all,
                     "a source moves along the list and stops at either end")

        // Evaluation with a wide table.
        let rates = ScratchpadCurrencyRates(date: "2026-10-25", base: "USD", rates: ["UAH": 45.5, "AED": 3.6725, "EUR": 0.9])
        let answer = ScratchpadCalculationEvaluator.evaluate("100 usd to uah\n10 aed + 5 eur",
            currencyRates: rates, decimalSeparator: ".", groupingSeparator: ",", locale: english)
        suite.expect(answer.lines[0].value == 4550 && answer.lines[1].value != nil,
                     "currencies beyond the first thirty convert like any other")
    }

    private static func calculationSyntax(_ suite: TestSuite) {
        let source = "rent = 900 eur\nper person: 90 / 3\n5 ft 11 in to cm\n20% of rent\nBook the train to Lisbon in May\nx in mi\n10:30"
        let answered: Set<Int> = [0, 1, 2, 3, 5]
        let spans = ScratchpadCalculationSyntax.spans(in: source) { answered.contains($0) }
        func words(_ role: ScratchpadCalculationSyntax.Role) -> [String] {
            spans.filter { $0.role == role }.map { (source as NSString).substring(with: $0.range) }
        }
        suite.expect(words(.variable) == ["rent"], "the name on the left of an assignment is picked out")
        suite.expect(words(.label) == ["per person:"], "a label before a calculation is picked out with its colon")
        suite.expect(words(.keyword) == ["to", "of", "in"],
                     "connecting words are picked out, and the inches in '5 ft 11 in to cm' are not mistaken for one")
        suite.expect(ScratchpadCalculationSyntax.spans(in: source) { _ in false }.isEmpty,
                     "lines without an answer, such as prose containing 'to' and 'in', are left alone")
        let inches = "12 in\n5 in + 3 in\ntotal in usd\n5 in cm"
        let inchSpans = ScratchpadCalculationSyntax.spans(in: inches) { _ in true }
        suite.expect(inchSpans.map { (inches as NSString).substring(with: $0.range) } == ["in", "in"]
                     && inchSpans.map { $0.range.location } == [inches.range(of: "total in")!.lowerBound.utf16Offset(in: inches) + 6,
                                                                inches.range(of: "5 in cm")!.lowerBound.utf16Offset(in: inches) + 2],
                     "'in' is a connecting word only before a unit or currency, not as the inches in '12 in' or '5 in + 3 in'")
        suite.expect(ScratchpadCalculationSyntax.flags(current: [true], previous: [false, true], lineCount: 2) == [true]
                     && ScratchpadCalculationSyntax.flags(current: [], previous: [false, true], lineCount: 2) == [false, true]
                     && ScratchpadCalculationSyntax.flags(current: [], previous: [false, true], lineCount: 3).isEmpty,
                     "earlier answers stand in while a new one is on its way, but not once the line count has changed")
        let windows = "a = 1\r\nb = 2"
        suite.expect(ScratchpadCalculationSyntax.spans(in: windows) { _ in true }.map(\.range)
                     == [NSRange(location: 0, length: 1), NSRange(location: 7, length: 1)],
                     "ranges follow the text across Windows line endings")
        suite.expect(ScratchpadCalculationSyntax.spans(in: "", answered: { _ in true }).isEmpty,
                     "an empty note has nothing to colour")
    }

    private static func primeNotation(_ suite: TestSuite) {
        let english = Locale(identifier: "en_US")
        func inches(_ input: String) -> Double? {
            CommandBarUnits.convert(input, decimalSeparator: ".", groupingSeparator: ",", locale: english)?.value
        }
        for input in ["5' 11\" in cm", "5'11\" in cm", "5 ft 11 in to cm", "5ft11in to cm", "5\u{2032} 11\u{2033} in cm"] {
            suite.expectClose(inches(input) ?? .nan, 180.34, "feet and inches convert: \(input)", tol: 0.001)
        }
        suite.expectClose(inches("5' in cm") ?? .nan, 152.4, "a bare foot mark means feet", tol: 0.001)
        suite.expectClose(inches("10\" in cm") ?? .nan, 25.4, "a bare inch mark means inches", tol: 0.001)
        suite.expect(inches("5\" 11' in cm") == nil, "inches before feet are not a height")
        suite.expect(CommandBarUnits.tokenize("5m² in cm") == ["5", "m²", "in", "cm"]
                     && CommandBarUnits.tokenize("3x4 in cm") == ["3", "x4", "in", "cm"]
                     && CommandBarUnits.tokenize("100km to mi") == ["100", "km", "to", "mi"],
                     "words that are not a chain of known units are not taken apart")
        let line = ScratchpadCalculationEvaluator.evaluate("5' 11\" in cm", decimalSeparator: ".", groupingSeparator: ",", locale: english)
        suite.expectClose(line.lines[0].value ?? .nan, 180.34, "a note line reads feet and inches written with marks", tol: 0.001)
    }

    private static func cache(_ suite: TestSuite) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-rates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rates.json")
        let saved = snapshot()
        suite.expect(ScratchpadExchangeRateCache.save(saved, to: url),
                     "a downloaded rate table is written to the private cache")
        suite.expect(ScratchpadExchangeRateCache.load(from: url) == saved,
                     "a saved rate table round-trips with its rate date and download time")
        suite.expect(ScratchpadExchangeRateCache.save(
            snapshot(date: "", rates: ScratchpadCurrencyRates.bundled.rates), to: url),
                     "the built-in table can be written without error")
        suite.expect(ScratchpadExchangeRateCache.load(from: url) == nil,
                     "the built-in table is never mistaken for a downloaded one")
        let malformedDate = #"{"rates":{"date":"not-a-date","base":"USD","rates":{"EUR":0.9}},"fetchedAt":800000000}"#
        try? Data(malformedDate.utf8).write(to: url)
        suite.expect(ScratchpadExchangeRateCache.load(from: url) == nil,
                     "a cached table with an unusable date is ignored")
        suite.expect(ScratchpadExchangeRateCache.load(
            from: directory.appendingPathComponent("missing.json")) == nil,
                     "a missing cache file falls back cleanly")

        let fresh = snapshot(fetchedAt: now)
        suite.expect(fresh.isFresh(now: now.addingTimeInterval(60)),
                     "a rate table is current for the day it was downloaded")
        suite.expect(!fresh.isFresh(now: now.addingTimeInterval(25 * 60 * 60)),
                     "a rate table is stale after a day even while its rate date is older")
        suite.expect(fresh.isFresh(now: now.addingTimeInterval(-60)),
                     "a small clock correction does not make the table stale")
    }

    private static func redirects(_ suite: TestSuite) {
        func allows(_ value: String, from original: String) -> Bool {
            guard let url = URL(string: value), let start = URL(string: original) else { return false }
            return ScratchpadExchangeRateRedirect.allows(URLRequest(url: url), from: URLRequest(url: start))
        }
        let origin = "https://api.frankfurter.dev/v2/rates"
        suite.expect(allows("https://api.frankfurter.dev/v2/other", from: origin),
                     "the rate request may follow a same-host HTTPS redirect")
        suite.expect(allows("https://API.FRANKFURTER.DEV/latest", from: origin),
                     "the same host is accepted regardless of case")
        suite.expect(!allows("https://rates.example/latest", from: origin),
                     "a redirect to another host is refused")
        suite.expect(!allows("http://api.frankfurter.dev/latest", from: origin),
                     "a redirect away from HTTPS is refused")
        suite.expect(!allows("https://api.frankfurter.dev.example/latest", from: origin),
                     "a host suffix cannot impersonate the provider")
        suite.expect(allows("https://cdn.jsdelivr.net/other.json", from: "https://cdn.jsdelivr.net/npm/usd.json")
                     && !allows("https://latest.currency-api.pages.dev/usd.json", from: "https://cdn.jsdelivr.net/npm/usd.json"),
                     "each source's redirects are held to that source's own host")
        suite.expect(!ScratchpadExchangeRateRedirect.allows(URLRequest(url: URL(string: origin)!), from: nil),
                     "a redirect with no original request is refused")
    }

    private final class RateProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let mode = request.url!.lastPathComponent
            let headers = mode == "length" ? ["Content-Length": "524289"] : [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = mode == "small" ? Data("{}".utf8) : Data(repeating: 32, count: 524289)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static func downloads(_ suite: TestSuite) {
        for mode in ["small", "length", "stream"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RateProtocol.self]
            var callbacks = 0
            var received: Result<(Data, HTTPURLResponse), Error>?
            ScratchpadExchangeRateHTTP.load(URLRequest(url: URL(string: "https://rates.invalid/\(mode)")!),
                                            configuration: configuration) { result in
                DispatchQueue.main.async { callbacks += 1; received = result }
            }
            suite.expect(wait { received != nil }, "HTTP download completes: \(mode)")
            if mode == "small" {
                suite.expect((try? received?.get().0) == Data("{}".utf8), "HTTP delegate delivers a bounded response")
            } else {
                if case .failure(let error) = received,
                   case ScratchpadExchangeRateHTTP.Failure.tooLarge = error {
                    suite.expect(true, "HTTP delegate rejects oversized \(mode) response")
                } else { suite.expect(false, "HTTP delegate rejects oversized \(mode) response") }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            suite.expect(callbacks == 1, "HTTP download delivers completion exactly once: \(mode)")
        }
    }

    private static func service(_ suite: TestSuite) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-rates-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rates.json")

        let cached = snapshot(fetchedAt: now.addingTimeInterval(-3600))
        _ = ScratchpadExchangeRateCache.save(cached, to: url)
        var cachedLoads = 0
        let cachedService = ScratchpadExchangeRateService(
            cacheURL: url,
            loader: { _, _ in cachedLoads += 1 },
            now: { now },
            sources: { [.frankfurter] })
        suite.expect(cachedService.rates == cached.rates && cachedService.hasCurrentRates,
                     "the service starts from a current saved table")
        cachedService.refreshIfNeeded()
        suite.expect(cachedLoads == 0,
                     "a current table avoids a network request")

        var requestSeen: URLRequest?
        var refreshCalls = 0
        let refreshURL = directory.appendingPathComponent("refreshed.json")
        let refreshService = ScratchpadExchangeRateService(
            cacheURL: refreshURL,
            loader: { request, complete in
                refreshCalls += 1
                requestSeen = request
                complete(.success((Data(payload.utf8), Self.response(for: request, status: 200))))
            },
            now: { now },
            sources: { [.frankfurter] })
        refreshService.refreshIfNeeded(force: true)
        suite.expect(wait { refreshCalls == 1 && !refreshService.isRefreshing },
                     "a requested refresh asks the loader once")
        suite.expect(requestSeen?.url?.host == "api.frankfurter.dev"
                     && requestSeen?.url?.path == "/v2/rates",
                     "the refresh uses the documented provider endpoint")
        let query = requestSeen?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let from = query.first { $0.name == "base" }?.value
        let to = Set((query.first { $0.name == "quotes" }?.value ?? "").split(separator: ",").map(String.init))
        suite.expect(from == "USD" && to.contains("EUR") && to.contains("UAH") && !to.contains("USD"),
                     "the refresh asks for every supported currency in one USD-based request")
        suite.expect(refreshService.rates.date == "2026-10-25"
                     && refreshService.rates.rates["EUR"] == 0.9
                     && refreshService.hasCurrentRates
                     && !refreshService.failed,
                     "a successful refresh updates the answer table")
        suite.expect(ScratchpadExchangeRateCache.load(from: refreshURL)?.rates == refreshService.rates,
                     "a successful refresh is saved for the next launch")

        var failureCalls = 0
        let failureService = ScratchpadExchangeRateService(
            cacheURL: nil,
            loader: { _, complete in
                failureCalls += 1
                complete(.failure(URLError(.notConnectedToInternet)))
            },
            now: { now },
            sources: { [.frankfurter] })
        let beforeFailure = failureService.rates
        failureService.refreshIfNeeded(force: true)
        suite.expect(wait { failureCalls == 1 && !failureService.isRefreshing },
                     "a failed refresh settles the loading state")
        suite.expect(failureService.failed && failureService.rates == beforeFailure,
                     "a failed refresh keeps the last usable table and reports the failure")
        failureService.refreshIfNeeded()
        suite.expect(failureCalls == 1,
                     "a failed refresh waits before the next automatic attempt")
        failureService.refreshIfNeeded(force: true)
        suite.expect(wait { failureCalls == 2 && !failureService.isRefreshing },
                     "the explicit action retries without waiting")

        var statusCalls = 0
        let statusService = ScratchpadExchangeRateService(
            cacheURL: nil,
            loader: { request, complete in
                statusCalls += 1
                complete(.success((Data(payload.utf8), Self.response(for: request, status: 500))))
            },
            now: { now },
            sources: { [.frankfurter] })
        statusService.refreshIfNeeded(force: true)
        suite.expect(wait { statusCalls == 1 && !statusService.isRefreshing },
                     "an error response settles the loading state")
        suite.expect(statusService.failed && statusService.rates.isBundled,
                     "an error response leaves the bundled table in place")

        chain(suite)
    }

    /// Sources are asked in order, and a later one only when it is needed.
    private static func chain(_ suite: TestSuite) {
        let fawaz = #"{"date":"2026-10-25","usd":{"eur":0.91,"uah":45.6}}"#
        let fullFawaz = "{\"date\":\"2026-10-25\",\"usd\":{"
            + ScratchpadCurrency.supportedSymbols.subtracting(["usd"]).sorted().map { "\"\($0)\":2" }.joined(separator: ",") + "}}"
        func run(sources: [ScratchpadRateProvider], bodies: [String: (Int, String)]) -> (ScratchpadExchangeRateService, [String]) {
            var hosts: [String] = []
            let service = ScratchpadExchangeRateService(
                cacheURL: nil,
                loader: { request, complete in
                    let host = request.url?.host ?? ""
                    hosts.append(host)
                    let (status, body) = bodies[host + (request.url?.path ?? "")] ?? bodies[host] ?? (500, "")
                    complete(.success((Data(body.utf8), Self.response(for: request, status: status))))
                },
                now: { now },
                sources: { sources })
            service.refreshIfNeeded(force: true)
            _ = wait { !service.isRefreshing && !hosts.isEmpty }
            return (service, hosts)
        }

        let complete = run(sources: [.frankfurter, .fawazahmed0],
                           bodies: ["api.frankfurter.dev": (200, fullPayload()), "latest.currency-api.pages.dev": (200, fawaz)])
        suite.expect(complete.1 == ["api.frankfurter.dev"] && !complete.0.failed,
                     "a second source is not contacted when the first returned every currency")

        let partial = run(sources: [.frankfurter, .fawazahmed0],
                          bodies: ["api.frankfurter.dev": (200, payload), "latest.currency-api.pages.dev": (200, fawaz)])
        suite.expect(partial.1 == ["api.frankfurter.dev", "latest.currency-api.pages.dev"],
                     "a second source is asked when the first lacked currencies")
        suite.expect(partial.0.rates.rates["EUR"] == 0.9 && partial.0.rates.rates["UAH"] == 45.6 && !partial.0.failed,
                     "the missing currency comes from the next source while the first keeps its own")

        let ecbFirst = run(sources: [.ecb, .frankfurter],
                           bodies: ["api.frankfurter.dev/v2/providers/ecb/rates": (200, payload),
                                    "api.frankfurter.dev/v2/rates": (200, fullPayload(date: "2026-10-26"))])
        suite.expect(ecbFirst.1 == ["api.frankfurter.dev", "api.frankfurter.dev"]
                     && ecbFirst.0.rates.rates["EUR"] == 0.9 && ecbFirst.0.rates.rates["UAH"] == 1.5,
                     "the ECB's figures win for its currencies and the blended table fills the rest")
        suite.expect(ecbFirst.0.rates.date == "2026-10-26" && !ecbFirst.0.failed,
                     "the date shown is the newest of the tables that contributed")
        let request = ScratchpadRateProvider.ecb.requests.first?.url
        suite.expect(request?.path == "/v2/providers/ecb/rates" && request?.host == "api.frankfurter.dev",
                     "the ECB source asks Frankfurter's provider endpoint")

        let fallback = run(sources: [.frankfurter, .fawazahmed0],
                           bodies: ["api.frankfurter.dev": (500, ""), "latest.currency-api.pages.dev": (200, fullFawaz)])
        suite.expect(fallback.0.rates.rates["UAH"] == 2 && fallback.0.rates.date == "2026-10-25" && !fallback.0.failed,
                     "a failing first source falls through to a next one that has every currency")
        let short = run(sources: [.ecb, .frankfurter],
                        bodies: ["api.frankfurter.dev/v2/providers/ecb/rates": (200, payload)])
        suite.expect(short.0.failed && short.0.rates.isBundled,
                     "a table left short of currencies by a failed source is not taken for a download")

        let mirror = run(sources: [.fawazahmed0],
                         bodies: ["latest.currency-api.pages.dev": (503, ""), "cdn.jsdelivr.net": (200, fawaz)])
        suite.expect(mirror.1 == ["latest.currency-api.pages.dev", "cdn.jsdelivr.net"] && mirror.0.rates.rates["UAH"] == 45.6,
                     "a source's mirror is tried when its first host fails")

        let single = run(sources: [.frankfurter], bodies: ["api.frankfurter.dev": (200, payload), "latest.currency-api.pages.dev": (200, fawaz)])
        suite.expect(single.1 == ["api.frankfurter.dev"] && single.0.rates.rates["UAH"] == nil,
                     "a source that is switched off is never contacted")

        let dead = run(sources: [.frankfurter, .fawazahmed0], bodies: [:])
        suite.expect(dead.0.failed && dead.0.rates.isBundled,
                     "every source failing reports the failure and keeps the built-in table")

        // A table short of currencies because a source failed keeps the fuller saved one.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vorssaint-rates-chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rates.json")
        let saved = snapshot(fetchedAt: now.addingTimeInterval(-30 * 3600),
                             rates: ["EUR": 0.9, "UAH": 45, "AED": 3.67], sources: "ecb,frankfurter")
        _ = ScratchpadExchangeRateCache.save(saved, to: url)
        var keptCalls = 0
        let keeping = ScratchpadExchangeRateService(
            cacheURL: url,
            loader: { request, complete in
                keptCalls += 1
                let ok = request.url?.path.contains("/providers/ecb/") == true
                complete(.success((Data((ok ? payload : "").utf8), Self.response(for: request, status: ok ? 200 : 500))))
            },
            now: { now },
            sources: { [.ecb, .frankfurter] })
        keeping.refreshIfNeeded()
        _ = wait { keptCalls == 2 && !keeping.isRefreshing }
        suite.expect(keeping.failed && keeping.rates == saved.rates
                     && ScratchpadExchangeRateCache.load(from: url)?.rates == saved.rates,
                     "one source failing never swaps a fuller saved table for a shorter one")
        keeping.refreshIfNeeded()
        suite.expect(keptCalls == 2, "the failed attempt waits before the next automatic one")

        // The saved table remembers which sources made it, so a change is noticed
        // mid-download and after a relaunch.
        var active: [ScratchpadRateProvider] = [.frankfurter]
        var calls = 0
        var held: ((Result<(Data, HTTPURLResponse), Error>) -> Void)?
        var hold = false
        let changeURL = directory.appendingPathComponent("changing.json")
        let changing = ScratchpadExchangeRateService(
            cacheURL: changeURL,
            loader: { request, complete in
                calls += 1
                if hold { held = { complete($0) }; return }
                complete(.success((Data(fullPayload().utf8), Self.response(for: request, status: 200))))
            },
            now: { now },
            sources: { active })
        changing.refreshIfNeeded(force: true)
        _ = wait { calls == 1 && !changing.isRefreshing }
        suite.expect(changing.hasCurrentRates, "a downloaded table is current")
        changing.refreshIfNeeded()
        suite.expect(calls == 1, "a current table is not downloaded again")
        active = [.ecb, .frankfurter]
        changing.sourcesDidChange()
        suite.expect(!changing.hasCurrentRates, "changing the sources makes the saved table stale")
        hold = true
        changing.refreshIfNeeded()
        suite.expect(wait { held != nil }, "the next refresh after a change asks again")
        active = [.ecb, .frankfurter, .fawazahmed0]
        changing.sourcesDidChange()
        held?(.success((Data(fullPayload().utf8), Self.response(for: URLRequest(url: URL(string: "https://api.frankfurter.dev/v2/rates")!), status: 200))))
        _ = wait { !changing.isRefreshing }
        suite.expect(!changing.hasCurrentRates,
                     "a change made while a download is under way is not forgotten when it finishes")
        let relaunched = ScratchpadExchangeRateService(cacheURL: changeURL, loader: { _, _ in }, now: { now },
                                                       sources: { [.ecb, .frankfurter] })
        suite.expect(relaunched.hasCurrentRates, "after a relaunch the saved table is current for the sources that made it")
        let other = ScratchpadExchangeRateService(cacheURL: changeURL, loader: { _, _ in }, now: { now },
                                                  sources: { [.frankfurter, .ecb] })
        suite.expect(!other.hasCurrentRates, "and not for the same sources in another order")
    }

    private static func currency(_ suite: TestSuite) {
        let rates = ScratchpadCurrencyRates(
            date: "2026-10-25", base: "USD",
            rates: ["EUR": 0.9, "JPY": 150, "PLN": 4.0])
        suite.expectClose(rates.convert(value: 100, from: "USD", to: "EUR") ?? .nan, 90,
                          "USD converts through the provider base")
        suite.expectClose(rates.convert(value: 20, from: "EUR", to: "PLN") ?? .nan, 88.8889,
                          "a cross rate converts through the provider base", tol: 0.001)
        suite.expect(rates.convert(value: 1, from: "USD", to: "GBP") == nil,
                     "a missing rate never invents an answer")

        let english = Locale(identifier: "en_US")
        let grouped = ScratchpadCurrency.convert(
            "1,000.50 usd to eur", rates: rates,
            decimalSeparator: ".", groupingSeparator: ",", locale: english)
        suite.expectClose(grouped?.value ?? .nan, 900.45, "grouping separators do not break a currency amount")
        suite.expect(grouped?.formatted.hasSuffix("EUR") == true,
                     "a currency answer names its target currency")
        let comma = ScratchpadCurrency.convert(
            "1.000,50 usd to eur", rates: rates,
            decimalSeparator: ",", groupingSeparator: ".", locale: Locale(identifier: "pt_BR"))
        suite.expectClose(comma?.value ?? .nan, 900.45,
                          "comma-decimal currency amounts parse with their locale")
        let yen = ScratchpadCurrency.convert(
            "10 usd to jpy", rates: rates,
            decimalSeparator: ".", groupingSeparator: ",", locale: english)
        suite.expect(yen?.formatted == "1,500 JPY",
                     "a zero-decimal currency is not shown with a fractional part")
        suite.expect(rates.localizedDate(locale: english)?.contains("2026") == true,
                     "a downloaded table shows the provider's rate date")
        suite.expect(ScratchpadCurrencyRates.bundled.localizedDate(locale: english) == nil,
                     "the built-in table does not claim a market date")
    }

    private static func evaluatorLines(_ suite: TestSuite) {
        let mixed = ScratchpadCalculationEvaluator.evaluate(
            "1 + 1\r\n2 + 2\rplain", decimalSeparator: ".", groupingSeparator: ",",
            locale: Locale(identifier: "en_US"))
        suite.expect(mixed.lines.map(\.value) == [2, 4, nil],
                     "Windows and classic Mac line endings keep their line positions")
        suite.expect(mixed.copyText.components(separatedBy: "\n").count == 3,
                     "calculation copy keeps the displayed line count")

        let numbers = ScratchpadCalculationEvaluator.evaluate(
            "5\n5 + 5", decimalSeparator: ".", groupingSeparator: ",",
            locale: Locale(identifier: "en_US"))
        suite.expect(numbers.copyText == "5\n5 + 5    10",
                     "copy does not repeat an answer that only restates a literal")
    }

    private static func accessibleAnswers(_ suite: TestSuite) {
        let storage = NSTextStorage(string: "2+3\n10 km + 5 mi")
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 430, height: 400))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = ScratchpadEditor.TextView(frame: NSRect(x: 0, y: 0, width: 430, height: 400), textContainer: container)
        view.calculationColumnWidth = 110
        view.calculationResults = ["5", "18.047 km"]
        let children = view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        suite.expect(view.accessibilityValue() == storage.string,
                     "accessible editable text remains the original source")
        suite.expect(children.map { $0.accessibilityLabel() ?? "" } == ["2+3 = 5", "10 km + 5 mi = 18.047 km"],
                     "each accessible answer includes its source expression")
        suite.expect(children.allSatisfy { $0.accessibilityRole() == .staticText && $0.accessibilityFrameInParentSpace().height > 0 },
                     "accessible answers expose text roles and source-line frames")
        let again = view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        suite.expect(children.first === again.first, "answer accessibility elements retain their identity")
        view.calculationResults = [nil, "18 km"]
        suite.expect(view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.count == 1,
                     "removed answers disappear from accessibility")
        view.calculationColumnWidth = 0
        suite.expect(view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.isEmpty == true,
                     "turning calculation mode off removes accessible answers")
    }

    private static func editorLayout(_ suite: TestSuite) {
        suite.expect(ScratchpadEditorLayout.lineStartLocations(in: "1 + 1\n2 + 2") == [0, 6],
                     "answer rows map to the start of each newline-separated line")
        suite.expect(ScratchpadEditorLayout.lineStartLocations(in: "1 + 1\r\n2 + 2") == [0, 7],
                     "a Windows line ending counts as one separator")
        suite.expect(ScratchpadEditorLayout.lineStartLocations(in: "1\n\n2") == [0, 2, 3],
                     "blank lines keep their place in the answer column")
        suite.expect(ScratchpadEditorLayout.lineStartLocations(in: "1\n") == [0, 2],
                     "an empty trailing line keeps its place without an answer")
        suite.expect(ScratchpadEditorLayout.lineStartLocations(in: "") == [0],
                     "an empty note still has one answer position")
        for source in ["1\n2", "1\r\n2", "1\n\n2", "1\n", ""] {
            let displayLines = source.isEmpty ? 1 : (ScratchpadEditorLayout.lineStartLocations(in: source).count)
            suite.expect(ScratchpadCalculationEvaluator.lines(in: source).count == displayLines,
                         "evaluation and display agree on line count for \(source.debugDescription)")
        }
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url ?? URL(string: "https://api.frankfurter.dev/v2/rates")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// The service applies loader results on the main queue, so the test run
    /// loop has to turn before the published values settle.
    private static func wait(timeout: TimeInterval = 2,
                             until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}
