import Foundation

enum InputCoordinates {
    /// Coordinate tools have one contract: integer milli-coordinates in
    /// 0...1000, measured from the top-left of the exact screenshot in use.
    static func normalizedFromMilli(_ v: Int, dimension: Int) throws -> Int {
        guard dimension > 1, (0...1_000).contains(v) else { throw AppError.invalid(String(localized: "Coordinates are outside the current screenshot")) }
        return Int((Double(v) / 1_000.0 * 65_535).rounded())
    }

    /// Converts pixel coordinates from a remote image-pixels-v1 observation
    /// into the local tool contract without guessing which unit the caller used.
    static func milliFromPixel(_ pixel: Int, dimension: Int) throws -> Int {
        guard dimension > 1, (0..<dimension).contains(pixel) else { throw AppError.invalid(String(localized: "Coordinates are outside the current screenshot")) }
        return Int((Double(pixel) / Double(dimension - 1) * 1_000).rounded())
    }

    static func normalized(pixel: Int, dimension: Int) throws -> Int {
        guard dimension > 1, pixel >= 0, pixel < dimension else { throw AppError.invalid(String(localized: "Coordinates are outside the current screenshot")) }
        return Int((Double(pixel) / Double(dimension - 1) * 65_535).rounded())
    }
}
