// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// A checked response plus the moment it arrived. The provider's date says
/// which day the rates belong to; `fetchedAt` decides when another request is
/// due. Keeping them separate matters on a weekend, when a fresh download can
/// still carry Friday's date.
struct ScratchpadExchangeRateSnapshot: Codable, Equatable {
    let rates: ScratchpadCurrencyRates
    let fetchedAt: Date
    /// The sources, in order, this table was downloaded from. A table made from
    /// other sources than the ones chosen now is not current, even when it is
    /// recent. Absent in tables saved before sources were chosen.
    var sources: String? = nil

    static let maximumAge: TimeInterval = 24 * 60 * 60

    func isFresh(now: Date, maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        abs(now.timeIntervalSince(fetchedAt)) < maximumAge
    }
}

enum ScratchpadExchangeRateParser {
    static let expectedBase = "USD"

    /// The provider writes ISO calendar dates. A malformed or impossible date
    /// fails the whole response rather than reaching the result column.
    static func validDate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        return parser.date(from: value) != nil
    }
}

enum ScratchpadExchangeRateCache {
    static var defaultURL: URL? {
        PrivateFileStore.containerURL?
            .appendingPathComponent("ScratchpadExchangeRates.json", isDirectory: false)
    }

    static func load(from url: URL) -> ScratchpadExchangeRateSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ScratchpadExchangeRateSnapshot.self, from: data),
              !snapshot.rates.isBundled,
              snapshot.rates.base.uppercased() == ScratchpadExchangeRateParser.expectedBase,
              ScratchpadExchangeRateParser.validDate(snapshot.rates.date),
              snapshot.fetchedAt.timeIntervalSince1970.isFinite,
              !snapshot.rates.rates.isEmpty,
              snapshot.rates.rates.allSatisfy({ $0.key.count == 3 && $0.value.isFinite && $0.value > 0 })
        else { return nil }
        return snapshot
    }

    static func save(_ snapshot: ScratchpadExchangeRateSnapshot, to url: URL) -> Bool {
        guard PrivateFileStore.createDirectory(at: url.deletingLastPathComponent()),
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        return PrivateFileStore.write(data, to: url)
    }
}

enum ScratchpadExchangeRateRedirect {
    /// A request may only hop within the HTTPS host it started on. A redirect
    /// to another address is treated as a failed download, never followed.
    static func allows(_ request: URLRequest, from original: URLRequest?) -> Bool {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let host = original?.url?.host?.lowercased() else { return false }
        return url.host?.lowercased() == host
    }
}

enum ScratchpadExchangeRateHTTP {
    enum Failure: Error {
        case invalidResponse
        case tooLarge
    }

    static func load(_ request: URLRequest,
                     completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Developer"
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Vorssaint/\(version) (https://github.com/vorssaint/vorssaint-utils)",
            "Accept": "application/json",
        ]
        load(request, configuration: configuration, completion: completion)
    }

    static func load(_ request: URLRequest, configuration: URLSessionConfiguration,
                     completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        let download = Download(completion: completion)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }

    // URLSession delivers this delegate's callbacks on one serial queue.
    private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private var data = Data()
        private var completion: ((Result<(Data, HTTPURLResponse), Error>) -> Void)?
        private let limit = 512 * 1024

        init(completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) {
            self.completion = completion
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if response.expectedContentLength > limit {
                finish(.failure(Failure.tooLarge))
                completionHandler(.cancel)
            } else { completionHandler(.allow) }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard chunk.count <= limit - data.count else {
                finish(.failure(Failure.tooLarge))
                dataTask.cancel()
                return
            }
            data.append(chunk)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer { session.finishTasksAndInvalidate() }
            if let error { finish(.failure(error)) }
            else if let response = task.response as? HTTPURLResponse { finish(.success((data, response))) }
            else { finish(.failure(Failure.invalidResponse)) }
        }

        private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            let callback = completion
            completion = nil
            callback?(result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(ScratchpadExchangeRateRedirect.allows(request, from: task.originalRequest) ? request : nil)
        }
    }
}

/// Currency rates for calculation mode. The app ships with a usable table, so
/// no note ever needs the network to answer. A download happens only after the
/// person turns daily updates on or asks for one, at most once a day
/// automatically, and a failed download leaves the previous table in place.
/// Sources are asked in the person's order, and a later one only when the ones
/// before it did not return every currency.
final class ScratchpadExchangeRateService: ObservableObject {
    static let shared = ScratchpadExchangeRateService()

    typealias Loader = (URLRequest, @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) -> Void

    @Published private(set) var rates: ScratchpadCurrencyRates
    @Published private(set) var isRefreshing = false
    @Published private(set) var failed = false

    private let cacheURL: URL?
    private let loader: Loader
    private let now: () -> Date
    private let sources: () -> [ScratchpadRateProvider]
    private var snapshot: ScratchpadExchangeRateSnapshot
    private var lastAttempt: Date?

    /// A failed automatic attempt waits before trying again, so opening notes
    /// while offline does not become a stream of requests. The explicit
    /// Update rates now action ignores this wait.
    private static let automaticRetryInterval: TimeInterval = 60 * 60

    init(cacheURL: URL? = ScratchpadExchangeRateCache.defaultURL,
         loader: @escaping Loader = ScratchpadExchangeRateHTTP.load,
         now: @escaping () -> Date = Date.init,
         sources: @escaping () -> [ScratchpadRateProvider] = {
             ScratchpadRateSources.enabledProviders(
                 from: UserDefaults.standard.string(forKey: DefaultsKey.scratchpadRateSources))
         }) {
        self.cacheURL = cacheURL
        self.loader = loader
        self.now = now
        self.sources = sources
        let cached = cacheURL.flatMap(ScratchpadExchangeRateCache.load(from:))
        let starting = cached ?? ScratchpadExchangeRateSnapshot(
            rates: .bundled, fetchedAt: .distantPast)
        snapshot = starting
        rates = starting.rates
    }

    private static func signature(_ providers: [ScratchpadRateProvider]) -> String {
        providers.map(\.rawValue).joined(separator: ",")
    }

    /// Whether the table in use is a recent download made from the sources the
    /// person has chosen now, in their order.
    var hasCurrentRates: Bool {
        snapshot.sources == Self.signature(sources()) && snapshot.isFresh(now: now())
    }

    private var retryIsDue: Bool {
        guard let lastAttempt else { return true }
        return abs(now().timeIntervalSince(lastAttempt)) >= Self.automaticRetryInterval
    }

    /// The person reordered or switched a source. The saved table remembers
    /// which sources made it, so it is no longer current; this lets the next
    /// automatic refresh run without waiting out an earlier failure.
    func sourcesDidChange() {
        lastAttempt = nil
    }

    /// A daily refresh for the automatic path; `force` backs the explicit
    /// Update rates now action. Loaders run off the main thread and each result
    /// is applied on the main thread before any view reads it.
    func refreshIfNeeded(force: Bool = false) {
        guard !isRefreshing else { return }
        let providers = sources()
        guard !providers.isEmpty, force || (retryIsDue && !hasCurrentRates) else { return }
        let signature = Self.signature(providers)
        lastAttempt = now()
        isRefreshing = true
        failed = false
        collect(providers[...], tables: [], failures: 0) { [weak self] tables, failures in
            guard let self else { return }
            self.isRefreshing = false
            // A table that is short of currencies because a source failed would
            // replace one that had them, so it is treated as a failed download.
            // Short because the chosen sources simply do not publish those
            // currencies is the person's choice and is kept.
            let complete = ScratchpadRateMerge.missing(from: tables).isEmpty
            guard let merged = ScratchpadRateMerge.merged(tables), complete || failures == 0 else {
                self.failed = true
                return
            }
            let next = ScratchpadExchangeRateSnapshot(rates: merged, fetchedAt: self.now(), sources: signature)
            self.snapshot = next
            self.rates = next.rates
            if let cacheURL = self.cacheURL {
                _ = ScratchpadExchangeRateCache.save(next, to: cacheURL)
            }
        }
    }

    /// Asks the sources in order until every supported currency has a rate or
    /// none is left, and counts the sources that gave nothing. A source that
    /// fails is skipped, not fatal.
    private func collect(_ providers: ArraySlice<ScratchpadRateProvider>, tables: [ScratchpadRateTable], failures: Int,
                         completion: @escaping ([ScratchpadRateTable], Int) -> Void) {
        guard let provider = providers.first else { completion(tables, failures); return }
        fetch(provider, requests: provider.requests[...]) { [weak self] table in
            guard let self else { return }
            let next = table.map { tables + [$0] } ?? tables
            let failed = failures + (table == nil ? 1 : 0)
            if ScratchpadRateMerge.missing(from: next).isEmpty { completion(next, failed); return }
            self.collect(providers.dropFirst(), tables: next, failures: failed, completion: completion)
        }
    }

    /// Tries a source's endpoints in turn; each one after the first is a mirror.
    private func fetch(_ provider: ScratchpadRateProvider, requests: ArraySlice<URLRequest>,
                       completion: @escaping (ScratchpadRateTable?) -> Void) {
        guard let request = requests.first else { completion(nil); return }
        loader(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .success(let (data, response)) = result, response.statusCode == 200,
                   let table = provider.table(from: data) {
                    completion(table)
                } else {
                    self.fetch(provider, requests: requests.dropFirst(), completion: completion)
                }
            }
        }
    }
}
