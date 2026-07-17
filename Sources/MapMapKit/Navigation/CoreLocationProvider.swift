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
/// Samples map platform sentinels to `nil`: negative
/// `horizontalAccuracy` (invalid fix channels), negative `speed` and
/// negative `course` are all reported as absent rather than passed
/// through.
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
        /// `location` background mode).
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
            #endif
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
            for location in locations {
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
