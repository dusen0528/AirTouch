import Foundation

public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Point(0, 0)
    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    public static func * (a: Point, b: Double) -> Point { Point(a.x * b, a.y * b) }
    public var length: Double { hypot(x, y) }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public func clamped(width: Double, height: Double) -> Point {
        Point(min(max(0, x), width), min(max(0, y), height))
    }
}

/// All landmarks use mirrored, top-left-origin normalized image coordinates.
public enum Joint: String, CaseIterable, Sendable {
    case wrist, thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    public static let chains: [[Joint]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]
}

public struct Landmark: Sendable {
    public let point: Point
    public let confidence: Double
    public init(_ point: Point, confidence: Double = 1) {
        self.point = point; self.confidence = confidence
    }
}

public struct HandFeatures: Sendable {
    public var index: Point
    public var palm: Point
    public var palmScale: Double
    public var pinchRatio: Double
    public var isPinchReliable: Bool
    public var secondaryPinchRatio: Double?
    public var isPointer: Bool
    public var isScroll: Bool
    public var isOpenPalm: Bool

    public init(index: Point, palm: Point, palmScale: Double = 0.15,
                pinchRatio: Double = 0.8, isPointer: Bool = true,
                isScroll: Bool = false, isOpenPalm: Bool = false,
                isPinchReliable: Bool = true, secondaryPinchRatio: Double? = nil) {
        self.index = index; self.palm = palm; self.palmScale = palmScale
        self.pinchRatio = pinchRatio; self.isPointer = isPointer
        self.isScroll = isScroll; self.isOpenPalm = isOpenPalm
        self.isPinchReliable = isPinchReliable; self.secondaryPinchRatio = secondaryPinchRatio
    }
    public var isValid: Bool {
        index.isFinite && palm.isFinite && palmScale.isFinite && palmScale > 0
            && pinchRatio.isFinite && pinchRatio >= 0
            && (secondaryPinchRatio.map { $0.isFinite && $0 >= 0 } ?? true)
    }
    public var isInActivationZone: Bool {
        (0.08...0.92).contains(palm.x) && (0.08...0.92).contains(palm.y)
    }
}

public enum FeatureExtractor {
    /// Uses pixel-aspect-correct distances, then normalizes by palm length.
    public static func extract(_ joints: [Joint: Landmark], width: Double, height: Double) -> HandFeatures? {
        guard width > 0, height > 0 else { return nil }
        func reliable(_ joint: Joint) -> Bool {
            guard let p = joints[joint] else { return false }
            return p.confidence >= 0.35 && p.point.isFinite
                && (0...1).contains(p.point.x) && (0...1).contains(p.point.y)
        }
        // Folded fingers are often occluded. They must not invalidate the visible
        // index and palm used for pointing. Unknown fingers never imply a scroll.
        guard [Joint.wrist, .indexMCP, .indexPIP, .indexTip, .middleMCP].allSatisfy(reliable) else { return nil }
        func point(_ j: Joint) -> Point { joints[j]!.point }
        func metric(_ j: Joint) -> Point { let p = point(j); return Point(p.x * width, p.y * height) }
        let scale = (metric(.wrist) - metric(.middleMCP)).length
        guard scale >= min(width, height) * 0.045 else { return nil }
        func extended(_ mcp: Joint, _ pip: Joint, _ dip: Joint, _ tip: Joint) -> Bool? {
            guard [mcp, pip, tip].allSatisfy(reliable) else { return nil }
            let a = metric(mcp) - metric(pip), b = metric(reliable(dip) ? dip : tip) - metric(pip)
            let divisor = a.length * b.length
            guard divisor > 1 else { return false }
            let cosine = (a.x * b.x + a.y * b.y) / divisor
            return cosine < -0.72
                && (metric(tip) - metric(mcp)).length > (metric(pip) - metric(mcp)).length * 1.35
        }
        let index = extended(.indexMCP, .indexPIP, .indexDIP, .indexTip)
        let middle = extended(.middleMCP, .middlePIP, .middleDIP, .middleTip)
        let ring = extended(.ringMCP, .ringPIP, .ringDIP, .ringTip)
        let little = extended(.littleMCP, .littlePIP, .littleDIP, .littleTip)
        let palm = (point(.wrist) + point(.indexMCP) + point(.middleMCP)) * (1 / 3.0)
        let thumbVisible = reliable(.thumbTip)
        return HandFeatures(index: point(.indexTip), palm: palm, palmScale: scale / height,
            pinchRatio: thumbVisible ? (metric(.thumbTip) - metric(.indexTip)).length / scale : 1,
            isPointer: index == true && middle != true && ring != true && little != true,
            isScroll: index == true && middle == true && ring != true && little != true,
            isOpenPalm: index == true && middle == true && ring == true && little == true,
            isPinchReliable: thumbVisible,
            secondaryPinchRatio: thumbVisible && reliable(.middleTip) ? (metric(.thumbTip) - metric(.middleTip)).length / scale : nil)
    }
}
