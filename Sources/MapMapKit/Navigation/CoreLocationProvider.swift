import CoreLocation
import Foundation

/// Live ``LocationProvider`` on Core Location.
///
/// The SDK's Info.plist declares **no** usage strings. Apps must add
/// `NSLocationWhenInUseUsageDescription` (and
/// `NSLocationAlwaysAndWhenInUseUsageDescription` plus the `location`
/// background mode for background guidance) and obtain authorisation
/// *before* the stream is consumed — see ios/README.md
/// ("Location authorisation"). If authorisation is denied while
/// streaming, the stream finishes by throwing `CLError.denied`.
///
/// Fixes Core Location marks invalid (a negative `horizontalAccuracy`)
/// are dropped, and so is a stale cached fix delivered as the stream
/// starts (older than ten seconds). In the samples that are forwarded,
/// platform sentinels map to `nil`: negative
/// `speed` and negative `course` are reported as absent rather than
/// passed through.
public final class CoreLocationProvider: LocationProvider {

    /// Configuration forwarded to `CLLocationManager`.
    public struct Configuration: Sendable {
        /// Desired accuracy; vehicular guidance wants
        /// `kCLLocationAccuracyBestForNavigation`.
        public var desiredAccuracy: CLLocationAccuracy
        /// Distance filter in metres (`kCLDistanceFilterNone` = every fix).
        public var distanceFilter: CLLocationDistance
        /// Activity type hint for the platform's fusion.
        public var activityType: CLActivityType
        /// Whether to request background updates (requires the app's
        /// `location` background mode; setting it without the mode
        /// declared raises an exception). When on, the platform is also
        /// told not to pause updates automatically, so a long wait at
        /// lights with the screen off does not end the stream.
        public var allowsBackgroundLocationUpdates: Bool

        public init(
            desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBestForNavigation,
            distanceFilter: CLLocationDistance = kCLDistanceFilterNone,
            activityType: CLActivityType = .automotiveNavigation,
            allowsBackgroundLocationUpdates: Bool = false
        ) {
            self.desiredAccuracy = desiredAccuracy
            self.distanceFilter = distanceFilter
            self.activityType = activityType
            self.allowsBackgroundLocationUpdates = allowsBackgroundLocationUpdates
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// A first fix older than this is Core Location's cached last-known
    /// position rather than a fix for this drive.
    static let maximumFirstFixAge: TimeInterval = 10
    /// How long after the stream starts the first-fix age check applies.
    /// Bounded so a device whose clock disagrees with its fix timestamps
    /// still gets a stream.
    static let firstFixAgeWindow: TimeInterval = 15

    /// Whether a Core Location fix is fit to feed guidance.
    ///
    /// A negative `horizontalAccuracy` is Core Location saying the
    /// coordinate itself is invalid. Forwarding it with an absent accuracy
    /// would have the navigation core trust it exactly, so it is dropped.
    ///
    /// Core Location may also deliver a cached fix first when updates
    /// start, minutes old and possibly from another place.
    /// `awaitingFirstFixSince` is when the stream started, for as long as
    /// it has not forwarded a fix yet (`nil` afterwards): within
    /// `firstFixAgeWindow` of that start, a fix older than
    /// `maximumFirstFixAge` is dropped. Later fixes are never dropped
    /// for their age.
    static func shouldForward(
        _ location: CLLocation, now: Date, awaitingFirstFixSince start: Date?
    ) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        guard let start, now.timeIntervalSince(start) < firstFixAgeWindow else { return true }
        return now.timeIntervalSince(location.timestamp) <= maximumFirstFixAge
    }

    /// When a stream started, until it has forwarded its first fix.
    /// Delegate callbacks are nonisolated, hence the lock.
    private final class FirstFixGate: @unchecked Sendable {
        private let lock = NSLock()
        private var start: Date?

        func begin(at date: Date) {
            lock.lock(); defer { lock.unlock() }
            start = date
        }

        var awaitingSince: Date? {
            lock.lock(); defer { lock.unlock() }
            return start
        }

        func forwarded() {
            lock.lock(); defer { lock.unlock() }
            start = nil
        }
    }

    public var locations: AsyncThrowingStream<LocationSample, Error> {
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            // CLLocationManager wants a run loop; the main actor has one.
            let bridgeTask = Task { @MainActor in
                let bridge = Bridge(configuration: configuration, continuation: continuation)
                bridge.start()
                // Keep the bridge alive until the stream terminates.
                await bridge.awaitTermination()
            }
            continuation.onTermination = { _ in
                bridgeTask.cancel()
            }
        }
    }

    /// Owns the `CLLocationManager` and forwards its delegate callbacks
    /// into the stream continuation.
    @MainActor
    private final class Bridge: NSObject, CLLocationManagerDelegate {
        private let manager = CLLocationManager()
        private let configuration: Configuration
        private let continuation: AsyncThrowingStream<LocationSample, Error>.Continuation
        private let firstFix = FirstFixGate()
        private var terminated: CheckedContinuation<Void, Never>?

        init(
            configuration: Configuration,
            continuation: AsyncThrowingStream<LocationSample, Error>.Continuation
        ) {
            self.configuration = configuration
            self.continuation = continuation
        }

        func start() {
            manager.delegate = self
            manager.desiredAccuracy = configuration.desiredAccuracy
            manager.distanceFilter = configuration.distanceFilter
            manager.activityType = configuration.activityType
            #if os(iOS)
                manager.allowsBackgroundLocationUpdates =
                    configuration.allowsBackgroundLocationUpdates
                if configuration.allowsBackgroundLocationUpdates {
                    // A paused manager delivers nothing more until the app
                    // is back in the foreground.
                    manager.pausesLocationUpdatesAutomatically = false
                }
            #endif
            firstFix.begin(at: Date())
            manager.startUpdatingLocation()
        }

        func awaitTermination() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (checked: CheckedContinuation<Void, Never>) in
                    terminated = checked
                }
            } onCancel: {
                Task { @MainActor in self.stop() }
            }
        }

        private func stop() {
            manager.stopUpdatingLocation()
            manager.delegate = nil
            terminated?.resume()
            terminated = nil
        }

        nonisolated func locationManager(
            _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
        ) {
            let now = Date()
            for location in locations {
                guard
                    CoreLocationProvider.shouldForward(
                        location, now: now, awaitingFirstFixSince: firstFix.awaitingSince)
                else { continue }
                firstFix.forwarded()
                continuation.yield(LocationSample(location))
            }
        }

        nonisolated func locationManager(
            _ manager: CLLocationManager, didFailWithError error: Error
        ) {
            // Transient failures (no fix yet) keep streaming; denial is
            // unrecoverable and surfaces to the consumer.
            if let clError = error as? CLError, clError.code == .denied {
                continuation.finish(throwing: error)
            }
        }
    }
}

extension LocationSample {
    /// Map a Core Location fix onto the SDK's sample, translating the
    /// platform's negative-value sentinels to `nil`.
    public init(_ location: CLLocation) {
        self.init(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            timestampMs: Int64((location.timestamp.timeIntervalSince1970 * 1000.0).rounded()),
            speedMps: location.speed >= 0 ? location.speed : nil,
            bearingDeg: location.course >= 0 ? location.course : nil,
            horizontalAccuracyM: location.horizontalAccuracy > 0
                ? location.horizontalAccuracy : nil
        )
    }
}
