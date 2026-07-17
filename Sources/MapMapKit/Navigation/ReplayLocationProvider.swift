import Foundation

/// Replays a `.drive.jsonl` corpus (the `sn-replay` QA format) as a
/// ``LocationProvider``.
///
/// Fix timestamps in the corpus are relative to drive start; they are
/// rebased onto `epochStartMs` so guidance sees monotonic
/// wall-clock-like times.
public struct ReplayLocationProvider: LocationProvider {

    private let corpus: DriveCorpus
    private let timeScale: Double
    private let epochStartMs: Int64

    /// - Parameters:
    ///   - corpus: a parsed corpus (see ``DriveCorpus/parse(_:)``).
    ///   - timeScale: playback speed: `1.0` = real time, `2.0` = twice as
    ///     fast, `0.0` = emit every fix immediately (unit tests).
    ///   - epochStartMs: epoch milliseconds assigned to the first fix.
    public init(corpus: DriveCorpus, timeScale: Double = 1.0, epochStartMs: Int64 = 0) {
        precondition(
            timeScale >= 0.0 && timeScale.isFinite,
            "timeScale must be finite and >= 0, got \(timeScale)")
        self.corpus = corpus
        self.timeScale = timeScale
        self.epochStartMs = epochStartMs
    }

    public var locations: AsyncThrowingStream<LocationSample, Error> {
        let corpus = self.corpus
        let timeScale = self.timeScale
        let epochStartMs = self.epochStartMs
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Parsed corpora always contain at least one fix.
                var previousTms = corpus.fixes[0].tMs
                for fix in corpus.fixes {
                    if Task.isCancelled { break }
                    if timeScale > 0.0 {
                        let gapMs = Double(fix.tMs - previousTms) / timeScale
                        if gapMs > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(gapMs * 1_000_000))
                        }
                    }
                    previousTms = fix.tMs
                    continuation.yield(fix.sample(epochStartMs: epochStartMs))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension DriveFix {
    /// Map one corpus fix to a ``LocationSample`` rebased on `epochStartMs`.
    public func sample(epochStartMs: Int64) -> LocationSample {
        LocationSample(
            lat: lat,
            lon: lon,
            timestampMs: epochStartMs + tMs,
            speedMps: speedMps,
            bearingDeg: bearingDeg,
            horizontalAccuracyM: horizontalAccuracyM
        )
    }
}
