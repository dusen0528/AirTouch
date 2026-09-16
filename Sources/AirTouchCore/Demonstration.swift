import Foundation

/// Synthetic features for reproducible practice demonstrations, not tracking evidence.
public struct Demonstration {
    public private(set) var frame = 0
    private var index = Point(0.5, 0.4)
    public static let totalFrames = 660
    private var dragLock = false
    public init(dragLock: Bool = false) { self.dragLock = dragLock }
    public var isFinished: Bool { frame >= Self.totalFrames }

    public mutating func next(cursor: Point, scene: PracticeScene, sensitivity: Double) -> HandFeatures {
        defer { frame += 1 }
        var pinch = false, scroll = false, rest = false
        var destination: Point?
        switch frame {
        case 0..<20: break
        case 20..<110: destination = scene.target
        case 110..<135: pinch = true
        case 135..<150: break
        case 150..<260: destination = scene.box
        case 260..<285: pinch = true
        case 285..<405: pinch = !dragLock || frame < 325; destination = scene.dropTarget
        case 405..<415: pinch = dragLock
        case 415..<425: break
        case 425..<445: scroll = true
        case 445..<505: scroll = true; index.y += 0.004
        case 505..<565: scroll = true; index.y -= 0.003
        case 565..<595: rest = true
        case 595..<615: break
        case 615..<660: destination = Point(380, 220)
        default: rest = true
        }
        if let destination {
            let error = destination - cursor
            index = index + Point(error.x / (760 * sensitivity), error.y / (440 * sensitivity)) * 0.08
        }
        return HandFeatures(index: index, palm: index + Point(0, 0.16),
            pinchRatio: pinch ? 0.16 : 0.75, isPointer: !scroll && !rest,
            isScroll: scroll, isOpenPalm: rest)
    }
}
