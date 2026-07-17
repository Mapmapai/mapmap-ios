import Foundation

/// Parser for the `.drive.jsonl` replay corpus format produced by the
/// workspace's `sn-replay` crate (see `crates/sn-replay/src/corpus.rs`).
///
/// Line 1 is a JSON header (`format_version`, `name`, `description`,
/// `route_fixture`, `seed`, optional `generator`); every following
/// non-blank line is one GPS fix (`t_ms`, `lat`, `lon`, optional
/// `speed_mps`, `bearing_deg`, `horizontal_accuracy_m`). The Swift parser
/// enforces the same invariants as the Rust one (and the Kotlin one in
/// `android/`): supported format version, non-empty name, at least one
/// fix, strictly increasing `t_ms`, and sane coordinate/channel ranges.
public struct DriveCorpus: Equatable, Sendable {
    /// The corpus format version this parser accepts.
    public static let formatVersion = 1

    public let header: DriveHeader
    public let fixes: [DriveFix]

    /// Parse and validate a corpus from JSON-lines text.
    ///
    /// - Throws: ``CorpusFormatError`` describing the first violation,
    ///   with its 1-based line number where applicable.
    public static func parse(_ jsonl: String) throws -> DriveCorpus {
        var header: DriveHeader?
        var fixes: [DriveFix] = []
        var previousTms: Int64?

        var line = 0
        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: false) {
            line += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard
                let data = trimmed.data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                throw CorpusFormatError("line \(line): invalid JSON")
            }
            if header == nil {
                header = try parseHeader(object, line: line)
            } else {
                let fix = try parseFix(object, line: line)
                if let previous = previousTms, fix.tMs <= previous {
                    throw CorpusFormatError(
                        "line \(line): t_ms \(fix.tMs) is not after previous fix at \(previous)")
                }
                previousTms = fix.tMs
                fixes.append(fix)
            }
        }

        guard let parsedHeader = header else {
            throw CorpusFormatError("corpus is missing its header line")
        }
        guard !fixes.isEmpty else {
            throw CorpusFormatError("corpus contains no GPS fixes")
        }
        return DriveCorpus(header: parsedHeader, fixes: fixes)
    }

    /// Read and parse a corpus file.
    public static func parse(contentsOf url: URL) throws -> DriveCorpus {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    private static func parseHeader(_ json: [String: Any], line: Int) throws -> DriveHeader {
        let version = (json["format_version"] as? NSNumber)?.intValue ?? -1
        guard version == formatVersion else {
            throw CorpusFormatError(
                "line \(line): unsupported corpus format version \(version) "
                    + "(supported: \(formatVersion))")
        }
        let name = json["name"] as? String ?? ""
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CorpusFormatError("line \(line): corpus header has an empty name")
        }
        return DriveHeader(
            formatVersion: version,
            name: name,
            description: json["description"] as? String ?? "",
            routeFixture: json["route_fixture"] as? String ?? "",
            seed: (json["seed"] as? NSNumber)?.int64Value ?? 0
        )
    }

    private static func parseFix(_ json: [String: Any], line: Int) throws -> DriveFix {
        guard
            let tMs = (json["t_ms"] as? NSNumber)?.int64Value,
            let lat = (json["lat"] as? NSNumber)?.doubleValue,
            let lon = (json["lon"] as? NSNumber)?.doubleValue
        else {
            throw CorpusFormatError("line \(line): fix requires t_ms, lat and lon")
        }
        guard lat.isFinite, (-90.0...90.0).contains(lat) else {
            throw CorpusFormatError("line \(line): latitude \(lat) is out of range")
        }
        guard lon.isFinite, (-180.0...180.0).contains(lon) else {
            throw CorpusFormatError("line \(line): longitude \(lon) is out of range")
        }
        let speed = optionalDouble(json, "speed_mps")
        if let speed, !speed.isFinite || speed < 0.0 {
            throw CorpusFormatError("line \(line): speed \(speed) m/s is invalid")
        }
        let bearing = optionalDouble(json, "bearing_deg")
        if let bearing, !bearing.isFinite || bearing < 0.0 || bearing >= 360.0 {
            throw CorpusFormatError("line \(line): bearing \(bearing) degrees is out of range")
        }
        let accuracy = optionalDouble(json, "horizontal_accuracy_m")
        if let accuracy, !accuracy.isFinite || accuracy <= 0.0 {
            throw CorpusFormatError("line \(line): horizontal accuracy \(accuracy) m is invalid")
        }
        return DriveFix(
            tMs: tMs,
            lat: lat,
            lon: lon,
            speedMps: speed,
            bearingDeg: bearing,
            horizontalAccuracyM: accuracy
        )
    }

    private static func optionalDouble(_ json: [String: Any], _ key: String) -> Double? {
        guard let value = json[key], !(value is NSNull) else { return nil }
        return (value as? NSNumber)?.doubleValue
    }
}

/// Header line of a `.drive.jsonl` corpus.
public struct DriveHeader: Equatable, Sendable {
    public let formatVersion: Int
    public let name: String
    public let description: String
    public let routeFixture: String
    public let seed: Int64
}

/// One GPS fix line of a corpus. `tMs` is milliseconds since drive start.
public struct DriveFix: Equatable, Sendable {
    public let tMs: Int64
    public let lat: Double
    public let lon: Double
    public let speedMps: Double?
    public let bearingDeg: Double?
    public let horizontalAccuracyM: Double?
}

/// A `.drive.jsonl` document violated the corpus format.
public struct CorpusFormatError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
