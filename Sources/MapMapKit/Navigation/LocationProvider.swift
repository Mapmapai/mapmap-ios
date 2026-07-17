import Foundation

/// One position sample fed into guidance.
public struct LocationSample: Equatable, Sendable {
    /// Latitude in decimal degrees (WGS84).
    public var lat: Double
    /// Longitude in decimal degrees (WGS84).
    public var lon: Double
    /// Milliseconds since the Unix epoch.
    public var timestampMs: Int64
    /// Speed over ground in metres per second, when the source reports it.
    public var speedMps: Double?
    /// Course over ground, degrees clockwise from true north, `[0, 360)`.
    public var bearingDeg: Double?
    /// Estimated 1-sigma horizontal accuracy in metres. Pass the platform
    /// value whenever available — the core uses it to gate step advance
    /// and deviation detection.
    public var horizontalAccuracyM: Double?

    public init(
        lat: Double,
        lon: Double,
        timestampMs: Int64,
        speedMps: Double? = nil,
        bearingDeg: Double? = nil,
        horizontalAccuracyM: Double? = nil
    ) {
        self.lat = lat
        self.lon = lon
        self.timestampMs = timestampMs
        self.speedMps = speedMps
        self.bearingDeg = bearingDeg
        self.horizontalAccuracyM = horizontalAccuracyM
    }
}

/// A source of location fixes for ``NavigationEngine``.
///
/// Implementations: ``CoreLocationProvider`` (Core Location) for live
/// navigation, ``ReplayLocationProvider`` (a `.drive.jsonl` corpus) for
/// QA and demos. Any stream of samples in ascending timestamp order
/// qualifies.
///
/// The stream is cold: every access to ``locations`` starts a fresh
/// sequence, and it is consumed once per navigation session.
public protocol LocationProvider: Sendable {
    /// A fresh stream of fixes. Finishes when the source is exhausted
    /// (replay) or throws on unrecoverable platform errors (live).
    var locations: AsyncThrowingStream<LocationSample, Error> { get }
}
