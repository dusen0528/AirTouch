import Foundation

public struct PracticeScene {
    public private(set) var clickCount = 0
    public private(set) var dropCount = 0
    public private(set) var scrollDistance = 0.0
    public private(set) var scrollOffset = 0.0
    public private(set) var box = Point(180, 310)
    public private(set) var isPressed = false
    public private(set) var isDragging = false
    public private(set) var lastEvent = "아직 입력 없음"
    public private(set) var eventCount = 0
    public let target = Point(380, 150)
    public let dropTarget = Point(550, 310)
    private var pressedOnTarget = false
    private var dragOffset: Point?
    public init() {}

    public mutating func apply(_ intent: InputIntent) {
        eventCount += 1
        switch intent {
        case .secondaryClick: lastEvent = "우클릭"
        case .move: lastEvent = "move"
        case .down(let p):
            guard !isPressed else { return }
            isPressed = true; pressedOnTarget = (p - target).length <= 32
            if abs(p.x - box.x) <= 38 && abs(p.y - box.y) <= 28 { dragOffset = box - p }
            lastEvent = "down"
        case .drag(let p):
            guard isPressed else { return }
            isDragging = true; pressedOnTarget = false
            if let dragOffset { box = p + dragOffset }
            lastEvent = "dragged"
        case .up(let p):
            guard isPressed else { return }
            if pressedOnTarget && !isDragging && (p - target).length <= 32 { clickCount += 1 }
            if isDragging && dragOffset != nil && (box - dropTarget).length <= 42 {
                dropCount += 1; box = Point(180, 310)
            }
            isPressed = false; isDragging = false; pressedOnTarget = false; dragOffset = nil
            lastEvent = "up"
        case .scroll(let delta):
            scrollOffset = min(900, max(0, scrollOffset + delta))
            scrollDistance += abs(delta); lastEvent = "scroll"
        }
    }
}
