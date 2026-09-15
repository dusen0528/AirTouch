import Foundation

/// A timestamp-aware One Euro filter. Inputs are normalized image coordinates.
public struct OneEuroFilter {
    public var minimumCutoff = 1.5
    // Coordinates are normalized, so motion speeds are fractions per second.
    // Raise cutoff during deliberate motion without removing idle smoothing.
    public var beta = 12.0
    private var raw: Point?
    private var value: Point?
    private var derivative = Point.zero
    private var lastTime: Double?

    public init() {}
    public mutating func reset() { raw = nil; value = nil; lastTime = nil; derivative = .zero }

    public mutating func update(_ point: Point, at time: Double) -> Point {
        guard let previousRaw = raw, let previous = value, let lastTime,
              time > lastTime, time - lastTime < 0.25 else {
            raw = point; value = point; self.lastTime = time; derivative = .zero
            return point
        }
        let dt = time - lastTime
        func alpha(_ cutoff: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }
        let velocity = (point - previousRaw) * (1 / dt)
        derivative = derivative + (velocity - derivative) * alpha(1)
        let cutoff = max(0.01, minimumCutoff) + max(0, beta) * derivative.length
        let filtered = previous + (point - previous) * alpha(cutoff)
        raw = point; value = filtered; self.lastTime = time
        return filtered
    }
}
