import Foundation

/// Turn-by-turn guidance over one computed route.
///
/// The Rust core's `GuidanceSession` (Ferrostar-based) is the navigation
/// state machine; this engine owns its lifecycle and adapts it to Swift
/// concurrency: stream ``LocationSample``s in from any
/// ``LocationProvider``, receive ``NavigationState``s out. The stream
/// completes after `arrived`. An engine is bound to a single route — on
/// `offRoute`, compute a new route and build a new engine (see
/// ``NavigationState/needsReroute``).
///
/// Ferrostar UI note: the Stadia Maps Ferrostar iOS packages
/// (https://github.com/stadiamaps/ferrostar — SwiftPM products
/// `FerrostarCore`, `FerrostarMapLibreUI`, `FerrostarSwiftUI`,
/// `FerrostarCarPlayUI`) can render on top of this state, but our
/// `GuidanceSession` remains the state machine — see ios/README.md,
/// "Ferrostar boundary".
public actor NavigationEngine {

    private let routeResponseJson: String
    private let config: GuidanceConfig

    private var session: GuidanceSession?
    private var lastSample: LocationSample?
    private var continuation: AsyncThrowingStream<NavigationState, Error>.Continuation?
    private var pumpTask: Task<Void, Never>?

    public init(routeResponseJson: String, config: GuidanceConfig = GuidanceConfig()) {
        self.routeResponseJson = routeResponseJson
        self.config = config
    }

    /// Build an engine from a route computed by
    /// ``OfflineRouting/route(router:waypoints:costing:adr:)``.
    public init(route: RouteResult, config: GuidanceConfig = GuidanceConfig()) {
        self.init(routeResponseJson: route.valhallaResponseJson, config: config)
    }

    /// Total number of steps in the route (including arrival) — for
    /// progress UIs. Opens a short-lived native session.
    ///
    /// - Throws: ``NavCoreError`` if the route response cannot start a
    ///   session (e.g. malformed JSON).
    public func totalSteps() throws -> UInt32 {
        try GuidanceSession(routeResponseJson: routeResponseJson, config: config).totalSteps()
    }

    /// Run guidance: feed every fix from `provider` into a fresh native
    /// session and emit the resulting states. Each call starts a new
    /// session at the first route step; a previous run on the same engine
    /// is stopped first. The stream completes after arrival, or fails
    /// with ``NavCoreError`` if the route response cannot start a
    /// session, or with the provider's error if the fix stream fails.
    public func navigate(provider: some LocationProvider) -> AsyncThrowingStream<
        NavigationState, Error
    > {
        stop()

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: NavigationState.self)
        self.continuation = continuation

        let newSession: GuidanceSession
        do {
            newSession = try GuidanceSession(
                routeResponseJson: routeResponseJson, config: config)
        } catch {
            finish(throwing: error)
            return stream
        }
        session = newSession

        // `Task {}` inherits this actor's isolation, so the guidance
        // maths (blocking FFI) runs on the engine's executor and
        // interleaves safely with `advanceToNextStep()`/`stop()`.
        pumpTask = Task { [locations = provider.locations] in
            do {
                for try await sample in locations {
                    if Task.isCancelled { break }
                    try self.consume(sample)
                }
                self.finish(throwing: nil)
            } catch is CancellationError {
                self.finish(throwing: nil)
            } catch {
                self.finish(throwing: error)
            }
        }

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.stop() }
        }
        return stream
    }

    /// Manually advance to the next step — the tunnel/no-GNSS escape
    /// hatch (Ferrostar exposes this on its navigator; the core forwards
    /// it). Ignored before the first fix of the active run, mirroring the
    /// Android SDK.
    public func advanceToNextStep() throws {
        guard let session, let lastSample, continuation != nil else { return }
        let update = try session.advanceToNextStep()
        yield(NavigationState(fix: lastSample, update: update))
    }

    /// Stop the active run, if any: the stream finishes without error and
    /// the native session is released.
    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        continuation?.finish()
        continuation = nil
        session = nil
        lastSample = nil
    }

    private func consume(_ sample: LocationSample) throws {
        guard let session else { return }
        lastSample = sample
        let update = try session.updateLocation(
            lat: sample.lat,
            lon: sample.lon,
            timestampMs: sample.timestampMs,
            speedMps: sample.speedMps,
            courseDeg: sample.bearingDeg,
            horizontalAccuracyM: sample.horizontalAccuracyM
        )
        yield(NavigationState(fix: sample, update: update))
    }

    private func yield(_ state: NavigationState) {
        continuation?.yield(state)
        if state.isArrived {
            finish(throwing: nil)
        }
    }

    private func finish(throwing error: Error?) {
        pumpTask?.cancel()
        pumpTask = nil
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
        session = nil
        lastSample = nil
    }
}
