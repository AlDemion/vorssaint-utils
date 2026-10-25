// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum ScratchpadExchangeRateTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let payload = """
    {"base":"USD","date":"2026-10-25","rates":{"EUR":0.9,"PLN":4.0,"JPY":150,"XYZ":2.0}}
    """

    static func run(_ suite: TestSuite) {
        parser(suite)
        cache(suite)
        redirects(suite)
        service(suite)
        currency(suite)
        evaluatorLines(suite)
        editorLayout(suite)
    }

    private static func snapshot(date: String = "2026-10-25",
                                 fetchedAt: Date = now,
                                 rates: [String: Double] = ["EUR": 0.9, "PLN": 4.0]) -> ScratchpadExchangeRateSnapshot {
        ScratchpadExchangeRateSnapshot(
            rates: ScratchpadCurrencyRates(date: date, base: "USD", rates: rates),
            fetchedAt: fetchedAt)
    }

    private static func parser(_ suite: TestSuite) {
        let parsed = ScratchpadExchangeRateParser.snapshot(from: Data(payload.utf8), fetchedAt: now)
        suite.expect(parsed?.rates.base == "USD" && parsed?.rates.date == "2026-10-25",
                     "exchange rate parser keeps the provider base and rate date")
        suite.expect(parsed?.rates.rates == ["EUR": 0.9, "PLN": 4.0, "JPY": 150],
                     "exchange rate parser keeps supported currencies and drops the rest")
        suite.expect(parsed?.fetchedAt == now,
                     "exchange rate parser records the download time separately from the rate date")

        let wrongBase = #"{"base":"EUR","date":"2026-10-25","rates":{"USD":1.1}}"#
        suite.expect(ScratchpadExchangeRateParser.snapshot(from: Data(wrongBase.utf8), fetchedAt: now) == nil,
                     "an unexpected base currency fails the response")
        for date in ["2026-02-30", "2026-10-2", "yesterday"] {
            let badDate = #"{"base":"USD","date":"\#(date)","rates":{"EUR":0.9}}"#
            suite.expect(ScratchpadExchangeRateParser.snapshot(from: Data(badDate.utf8), fetchedAt: now) == nil,
                         "an impossible rate date fails the response: \(date)")
        }
        let empty = #"{"base":"USD","date":"2026-10-25","rates":{"XYZ":2.0}}"#
        suite.expect(ScratchpadExchangeRateParser.snapshot(from: Data(empty.utf8), fetchedAt: now) == nil,
                     "a response with no supported currency is rejected")
        let broken = #"{"base":"USD","date":"2026-10-25","rates":{"EUR":0}}"#
        suite.expect(ScratchpadExchangeRateParser.snapshot(from: Data(broken.utf8), fetchedAt: now) == nil,
                     "a zero rate is rejected")
        suite.expect(ScratchpadExchangeRateParser.snapshot(from: Data("not json".utf8), fetchedAt: now) == nil,
                     "malformed JSON is rejected")
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
        func allows(_ value: String) -> Bool {
            guard let url = URL(string: value) else { return false }
            return ScratchpadExchangeRateRedirect.allows(URLRequest(url: url))
        }
        suite.expect(allows("https://api.frankfurter.app/latest"),
                     "the rate request may follow a same-host HTTPS redirect")
        suite.expect(allows("https://API.FRANKFURTER.APP/latest"),
                     "the same host is accepted regardless of case")
        suite.expect(!allows("https://rates.example/latest"),
                     "a redirect to another host is refused")
        suite.expect(!allows("http://api.frankfurter.app/latest"),
                     "a redirect away from HTTPS is refused")
        suite.expect(!allows("https://api.frankfurter.app.example/latest"),
                     "a host suffix cannot impersonate the provider")
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
            now: { now })
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
            now: { now })
        refreshService.refreshIfNeeded(force: true)
        suite.expect(wait { refreshCalls == 1 && !refreshService.isRefreshing },
                     "a requested refresh asks the loader once")
        suite.expect(requestSeen?.url?.host == "api.frankfurter.app"
                     && requestSeen?.url?.path == "/latest",
                     "the refresh uses the documented provider endpoint")
        let query = requestSeen?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let from = query.first { $0.name == "from" }?.value
        let to = Set((query.first { $0.name == "to" }?.value ?? "").split(separator: ",").map(String.init))
        suite.expect(from == "USD" && to.contains("EUR") && to.contains("PLN") && !to.contains("USD"),
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
            now: { now })
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
            now: { now })
        statusService.refreshIfNeeded(force: true)
        suite.expect(wait { statusCalls == 1 && !statusService.isRefreshing },
                     "an error response settles the loading state")
        suite.expect(statusService.failed && statusService.rates.isBundled,
                     "an error response leaves the bundled table in place")
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
        HTTPURLResponse(url: request.url ?? URL(string: "https://api.frankfurter.app/latest")!,
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
