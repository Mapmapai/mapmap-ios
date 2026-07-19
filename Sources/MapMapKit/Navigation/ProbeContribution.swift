import Foundation

/// Where a completed probe batch goes. Called off the guidance stream, so
/// ``enqueue(_:)`` must not block and must never throw.
public protocol ProbeUploader: Sendable {
    /// Hand one probe body — the string from `ProbeCollector.finishJson` — off
    /// to be POSTed to `/v1/probe`. Fire-and-forget.
    func enqueue(_ body: String)
}

/// The outcome of one upload attempt, surfaced through
/// ``URLSessionProbeUploader``'s result callback for observability and tests.
public enum ProbeUploadOutcome: Sendable, Equatable {
    /// `202` — accepted and stored.
    case accepted
    /// `403` — the key is not opted in; dropped, not retried.
    case refused
    /// `501` — server collection is not enabled (`SN_PROBE_DIR` unset); dropped.
    case notEnabled
    /// `400`/other 4xx — malformed or unacceptable; dropped, not retried.
    case rejected
    /// Transport error or `5xx` after exhausting retries; given up on.
    case gaveUp
}

/// Accumulate an aggregate probe batch from a guidance stream and upload it
/// when the trip ends. **A transparent pass-through when `config.enabled` is
/// false** (the shipped default): no collector is constructed and nothing is
/// uploaded, so leaving collection off costs nothing.
///
/// Wrap it around ``NavigationEngine/navigate(provider:)``'s stream:
/// ```swift
/// let stream = contributingProbe(
///     await engine.navigate(provider: provider),
///     config: ProbeConfig(enabled: consentGranted),
///     uploader: URLSessionProbeUploader(baseURL: "https://api.mapmap.ai", apiKey: key),
///     routeRef: servedRouteToken, territory: "uk", vehicleClass: "truck_40t"
/// )
/// for try await state in stream { render(state) }
/// ```
///
/// Consent is the caller's responsibility: only pass `enabled: true` for a key
/// whose operator has set `probe_opt_in` and — for a consumer app — with the
/// user's opt-in consent. See `docs/PROBE-SDK-INTEGRATION.md`.
///
/// Only aggregates leave the device: the collector cannot emit a trajectory,
/// and the first/last stretch of every trip is discarded on-device.
///
/// - Parameters:
///   - routeRef: opaque served-route token so the server can resolve segment
///     indices.
///   - vehicleClass: a costing class only — never a registration, VIN or
///     driver id.
///   - now: injectable clock (Unix millis) for deterministic tests.
public func contributingProbe(
    _ upstream: AsyncThrowingStream<NavigationState, Error>,
    config: ProbeConfig,
    uploader: ProbeUploader,
    routeRef: String? = nil,
    territory: String? = nil,
    vehicleClass: String? = nil,
    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
) -> AsyncThrowingStream<NavigationState, Error> {
    guard config.enabled else { return upstream }

    return AsyncThrowingStream<NavigationState, Error> { continuation in
        let task = Task {
            let collector = ProbeCollector(config: config)
            routeRef.map { collector.setRouteRef(routeRef: $0) }
            territory.map { collector.setTerritory(territory: $0) }
            vehicleClass.map { collector.setVehicleClass(vehicleClass: $0) }

            var arrived = false
            // finishJson is a cheap native call, safe on any completion path
            // (an abandoned trip still applies end suppression). A nil body
            // means there was nothing worth uploading. Enqueue is
            // fire-and-forget, so teardown is never delayed.
            func flush() {
                if let body = collector.finishJson(arrived: arrived, timestampMs: now()) {
                    uploader.enqueue(body)
                }
            }

            do {
                for try await state in upstream {
                    arrived = state.isArrived
                    collector.observe(
                        update: state.update,
                        fixLat: state.fix.lat,
                        fixLon: state.fix.lon,
                        speedMps: state.fix.speedMps,
                        timestampMs: state.fix.timestampMs
                    )
                    continuation.yield(state)
                }
                flush()
                continuation.finish()
            } catch {
                flush()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Default ``ProbeUploader``: POSTs each body to `{baseURL}/v1/probe` with a
/// bearer key via `URLSession`. Transient failures (transport or `5xx`) are
/// retried with bounded backoff; permanent ones (`400`/`403`/`501`) are
/// dropped. No third-party dependency.
public final class URLSessionProbeUploader: ProbeUploader, @unchecked Sendable {
    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession
    private let maxAttempts: Int
    private let backoff: @Sendable (Int) -> TimeInterval
    private let onResult: @Sendable (ProbeUploadOutcome) -> Void

    /// - Parameters:
    ///   - baseURL: gateway origin, e.g. `https://api.mapmap.ai` (a trailing
    ///     slash is tolerated).
    ///   - maxAttempts: total tries including the first.
    ///   - backoff: attempt number → delay before the next try.
    public init(
        baseURL: String,
        apiKey: String,
        session: URLSession = .shared,
        maxAttempts: Int = 4,
        backoff: @escaping @Sendable (Int) -> TimeInterval = { TimeInterval($0) },
        onResult: @escaping @Sendable (ProbeUploadOutcome) -> Void = { _ in }
    ) {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + "/v1/probe") else {
            preconditionFailure("invalid probe base URL: \(baseURL)")
        }
        self.endpoint = url
        self.apiKey = apiKey
        self.session = session
        self.maxAttempts = maxAttempts
        self.backoff = backoff
        self.onResult = onResult
    }

    public func enqueue(_ body: String) {
        post(body, attempt: 1)
    }

    private func post(_ body: String, attempt: Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let outcome = Self.classify(response: response, error: error)
            if outcome == .gaveUp, attempt < self.maxAttempts {
                let delay = self.backoff(attempt)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.post(body, attempt: attempt + 1)
                }
            } else {
                self.onResult(outcome)
            }
        }
        task.resume()
    }

    private static func classify(response: URLResponse?, error: Error?) -> ProbeUploadOutcome {
        if error != nil { return .gaveUp }
        guard let http = response as? HTTPURLResponse else { return .gaveUp }
        switch http.statusCode {
        case 202: return .accepted
        case 403: return .refused
        case 501: return .notEnabled
        case 500...599: return .gaveUp
        default: return .rejected
        }
    }
}
