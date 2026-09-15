import Foundation

/// Coordinates are logical CoreGraphics display coordinates; never apply Retina scale.
public struct DisplayArea: Equatable, Sendable {
    public let origin: Point
    public let width: Double
    public let height: Double
    public init(origin: Point, width: Double, height: Double) {
        self.origin = origin; self.width = width; self.height = height
    }
    public func global(_ local: Point) -> Point {
        origin + local.clamped(width: max(0, width - 1), height: max(0, height - 1))
    }
    public func local(_ global: Point) -> Point {
        (global - origin).clamped(width: max(0, width - 1), height: max(0, height - 1))
    }
}

/// The final gate runs on the output queue, separate from UI and Vision.
public struct SystemOutputGate {
    public private(set) var active = false
    public private(set) var held = false
    public private(set) var generation = -1
    public private(set) var position = Point.zero
    private var lastFrame = 0.0
    private var lastDelivery = 0.0
    private var lastValidHand = 0.0
    public init() {}

    public mutating func begin(generation: Int, position: Point, now: Double) -> [InputIntent] {
        let releases = stop()
        self.generation = generation; self.position = position
        // The first frame was captured before begin() was called by its receiver.
        // Session identity rejects old sessions; capture age rejects stale input.
        active = true; lastFrame = -.infinity; lastDelivery = now; lastValidHand = -.infinity
        return releases
    }
    public mutating func heartbeat(generation: Int, capturedAt: Double, validHand: Bool, now: Double) {
        guard active, generation == self.generation, capturedAt > lastFrame,
              capturedAt <= now, now - capturedAt < 0.2 else { return }
        lastFrame = capturedAt; lastDelivery = now
        if validHand { lastValidHand = capturedAt }
    }
    public mutating func accept(_ intents: [InputIntent], generation: Int, now: Double, permitted: Bool) -> [InputIntent] {
        guard active, generation == self.generation else { return [] }
        guard permitted, now - lastDelivery < 0.25 else { return stop() }
        var result: [InputIntent] = []
        for intent in intents {
            switch intent {
            case .secondaryClick(let p):
                guard p.isFinite, !held, now - lastValidHand < 0.2 else { continue }
                position = p; result.append(intent)
            case .move(let p):
                guard p.isFinite, !held, now - lastValidHand < 0.2 else { continue }
                position = p; result.append(intent)
            case .down(let p):
                guard p.isFinite, !held, now - lastValidHand < 0.2 else { continue }
                position = p; held = true; result.append(intent)
            case .drag(let p):
                guard p.isFinite, held, now - lastValidHand < 0.2 else { continue }
                position = p; result.append(intent)
            case .up(let p):
                guard held else { continue }
                held = false
                if p.isFinite { position = p }
                result.append(.up(position))
            case .scroll(let delta):
                guard delta.isFinite, !held, now - lastValidHand < 0.2 else { continue }
                result.append(intent)
            }
        }
        return result
    }
    public mutating func expire(now: Double, permitted: Bool) -> [InputIntent] {
        guard active else { return [] }
        if !permitted || now - lastDelivery >= 0.25 || (held && now - lastValidHand >= 0.2) { return stop() }
        return []
    }
    public mutating func stop() -> [InputIntent] {
        let releases: [InputIntent] = held ? [.up(position)] : []
        held = false; active = false
        return releases
    }
}
