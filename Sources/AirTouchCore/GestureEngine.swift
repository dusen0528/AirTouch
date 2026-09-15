import Foundation

public enum GestureState: String, Sendable {
    case suspended, pointer, pinchCandidate, pressed, dragging, scrolling
    public var label: String {
        switch self {
        case .suspended: return "준비 / 쉬기"
        case .pointer: return "커서 이동"
        case .pinchCandidate: return "핀치 확인 중"
        case .pressed: return "누르고 있음"
        case .dragging: return "드래그"
        case .scrolling: return "스크롤"
        }
    }
}

public enum InputIntent: Equatable, Sendable {
    case move(Point), down(Point), drag(Point), up(Point), scroll(Double), secondaryClick(Point)
}

public enum ControlStyle: String, CaseIterable, Sendable {
    case comfortable, direct

    public var label: String { self == .comfortable ? "편안하게" : "손끝으로 직접" }
    public var detail: String {
        self == .comfortable
            ? "검지를 편 채 손 전체를 움직이세요. 천천히 움직이면 정밀하게, 빠르게 움직이면 멀리 이동합니다."
            : "검지 끝의 움직임을 일정한 속도로 반영합니다."
    }
}

public struct GestureConfiguration: Sendable {
    public var controlStyle: ControlStyle = .comfortable
    public var activationDuration = 0.35
    public var pinchDuration = 0.08
    public var scrollDuration = 0.18
    public var poseGraceDuration = 0.12
    public var handLossTimeout = 0.12
    public var frameTimeout = 0.20
    public var pinchEnter = 0.25
    public var pinchExit = 0.38
    public var dragThreshold = 8.0
    public var sensitivity = 1.6
    public var smoothing = 1.5
    public var scrollMultiplier = 1.0
    public init() {}

}

/// Pure, deterministic controller. No camera, UI, or OS input dependencies.
/// Call tick independently of camera delivery so lost frames release pressed inputs.
public struct GestureEngine {
    public var configuration = GestureConfiguration()
    public private(set) var state: GestureState = .suspended
    public private(set) var cursor = Point(380, 220)
    public private(set) var reason = "검지만 펴고 잠시 유지하세요"
    public private(set) var progress = 0.0
    public private(set) var generation = 0
    public private(set) var enabled = false
    private var width = 760.0
    private var height = 440.0
    private var sequence = -1
    private var lastFrameTime: Double?
    // Hand loss measures time without a delivered valid observation. Capture age
    // is checked independently by lastFrameTime; inference time is not hand loss.
    private var lastValidTime: Double?
    private var activationStart: Double?
    private var candidateStart: Double?
    private var scrollStart: Double?
    private var uncertainPoseStart: Double?
    private var pinchLatched = false
    private var secondaryPinch = false
    private var buttonDown = false
    private var lastHand: HandFeatures?
    private var previousPoint: Point?
    private var pressPalm: Point?
    private var previousScroll: Point?
    private var filter = OneEuroFilter()
    private var palmFilter = OneEuroFilter()
    private var residual = Point.zero
    private var recovering = false

    public init() {}

    /// Rebase after physical input, display changes, or switching output destinations.
    public mutating func rebase(to point: Point, width: Double, height: Double) -> [InputIntent] {
        let actions = resize(width: width, height: height)
        if point.isFinite { cursor = point.clamped(width: max(0, width - 1), height: max(0, height - 1)) }
        return actions
    }

    public mutating func pause(reason: String) -> [InputIntent] { suspend(reason) }

    @discardableResult public mutating func start() -> [InputIntent] {
        let actions = suspend("검지만 펴고 잠시 유지하세요")
        generation += 1; sequence = -1; lastFrameTime = nil; lastValidTime = nil
        enabled = true; lastHand = nil
        return actions
    }

    @discardableResult public mutating func stop(reason: String = "연습이 멈췄습니다") -> [InputIntent] {
        let actions = suspend(reason)
        enabled = false; generation += 1; lastHand = nil
        return actions
    }

    public mutating func resize(width: Double, height: Double) -> [InputIntent] {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return [] }
        let actions = suspend("연습 영역이 바뀌었습니다. 검지를 펴서 재개하세요")
        self.width = width; self.height = height
        cursor = cursor.clamped(width: width, height: height)
        return actions
    }

    public mutating func tick(at time: Double) -> [InputIntent] {
        guard enabled else { return [] }
        if let lastFrameTime, time - lastFrameTime >= configuration.frameTimeout {
            return suspend("영상이 멈췄습니다. 입력을 해제했습니다")
        }
        if let lastValidTime, time - lastValidTime >= configuration.handLossTimeout {
            return suspend("손을 찾는 중 · 검지를 펴서 재개하세요")
        }
        return []
    }

    public mutating func process(_ hand: HandFeatures?, sequence: Int, generation: Int,
                                 capturedAt time: Double, now: Double) -> [InputIntent] {
        guard enabled, generation == self.generation, sequence > self.sequence,
              time.isFinite, now.isFinite, now >= time,
              now - time < configuration.frameTimeout,
              lastFrameTime.map({ time > $0 }) ?? true else { return [] }
        // Enforce timeouts even when a new frame wins the race with the watchdog.
        var actions = tick(at: now)
        let frameInterval = lastFrameTime.map { time - $0 } ?? (1 / 30)
        self.sequence = sequence; lastFrameTime = time
        guard let hand, hand.isValid else {
            activationStart = nil; scrollStart = nil; progress = 0
            recovering = true
            if state == .pinchCandidate { actions += suspend("손 전체를 보여주세요") }
            return actions
        }
        if let previous = lastHand {
            let scaleRatio = hand.palmScale / previous.palmScale
            if (hand.palm - previous.palm).length > 0.22 || !(0.55...1.8).contains(scaleRatio) {
                actions += suspend("손이 바뀌었거나 크게 움직였습니다. 다시 시작하세요")
                lastHand = hand; lastValidTime = now
                return actions
            }
        }
        lastHand = hand; lastValidTime = now
        if !hand.isPinchReliable {
            if state == .pinchCandidate || state == .pressed || state == .dragging {
                return actions + suspend("엄지가 가려져 입력을 해제했습니다")
            }
            pinchLatched = false
        }
        if secondaryPinch && (state == .pinchCandidate || state == .pressed), hand.secondaryPinchRatio == nil {
            return actions + suspend("중지가 가려져 우클릭을 취소했습니다")
        }
        filter.minimumCutoff = configuration.smoothing
        palmFilter.minimumCutoff = configuration.smoothing
        if recovering {
            filter.reset(); palmFilter.reset(); previousPoint = nil; previousScroll = nil
            pressPalm = hand.palm; residual = .zero; recovering = false
        }
        let index = filter.update(hand.index, at: time)
        let palm = palmFilter.update(hand.palm, at: time)
        let pointer = configuration.controlStyle == .comfortable ? palm : index
        if state == .pointer || state == .suspended {
            secondaryPinch = hand.secondaryPinchRatio.map { $0 < configuration.pinchEnter && $0 < hand.pinchRatio } ?? false
        }
        let ratio = secondaryPinch ? (hand.secondaryPinchRatio ?? 1) : hand.pinchRatio
        if hand.isPinchReliable && ratio < configuration.pinchEnter { pinchLatched = true }
        else if ratio > configuration.pinchExit { pinchLatched = false }

        if hand.isOpenPalm { return actions + suspend("쉬는 중 · 검지를 펴면 다시 시작합니다") }

        switch state {
        case .suspended:
            guard hand.isPointer, !pinchLatched, hand.isInActivationZone else {
                activationStart = nil; progress = 0; return actions
            }
            if activationStart == nil { activationStart = time }
            progress = min(1, (time - activationStart!) / configuration.activationDuration)
            if time - activationStart! >= configuration.activationDuration {
                state = .pointer; previousPoint = pointer; residual = .zero
                reason = "검지를 움직이세요 · 핀치로 클릭"; progress = 0; activationStart = nil
            }
        case .pointer:
            if pinchLatched {
                uncertainPoseStart = nil
                state = .pinchCandidate; candidateStart = time; previousPoint = nil; progress = 0
                scrollStart = nil
                reason = secondaryPinch ? "엄지와 중지를 모으면 우클릭" : "핀치를 잠시 유지하세요"
            } else if hand.isScroll {
                uncertainPoseStart = nil
                if scrollStart == nil { scrollStart = time }
                previousPoint = nil
                progress = min(1, (time - scrollStart!) / configuration.scrollDuration)
                if time - scrollStart! >= configuration.scrollDuration {
                    // Discard the filter tail of movement made before entering scroll.
                    palmFilter.reset()
                    state = .scrolling; previousScroll = palmFilter.update(hand.palm, at: time); progress = 0
                    reason = "손을 위아래로 움직이세요"
                }
            } else if hand.isPointer {
                uncertainPoseStart = nil
                scrollStart = nil; progress = 0
                actions += move(pointer, dragging: false, interval: frameInterval)
            } else {
                if uncertainPoseStart == nil { uncertainPoseStart = time }
                previousPoint = nil; recovering = true
                scrollStart = nil; progress = 0
                if time - uncertainPoseStart! >= configuration.poseGraceDuration {
                    actions += suspend("검지만 펴면 다시 시작합니다")
                }
            }
        case .pinchCandidate:
            if !pinchLatched {
                state = .pointer; previousPoint = resetPointer(hand, at: time); candidateStart = nil; progress = 0
                reason = "짧은 핀치 무시됨"
            } else if let candidateStart {
                progress = min(1, (time - candidateStart) / configuration.pinchDuration)
                if time - candidateStart >= configuration.pinchDuration {
                    state = .pressed; buttonDown = !secondaryPinch; pressPalm = palm; previousPoint = nil
                    reason = secondaryPinch ? "손가락을 놓으면 우클릭" : "놓으면 클릭 · 손을 움직이면 드래그"; progress = 0
                    if !secondaryPinch { actions.append(.down(cursor)) }
                }
            }
        case .pressed, .dragging:
            if !pinchLatched {
                if buttonDown { actions.append(.up(cursor)); buttonDown = false }
                if secondaryPinch { actions.append(.secondaryClick(cursor)) }
                state = .pointer; previousPoint = resetPointer(hand, at: time); residual = .zero
                pressPalm = nil; reason = "입력 해제됨"
            } else if state == .pressed, let pressPalm {
                let delta = scaled(palm - pressPalm)
                if delta.length > configuration.dragThreshold {
                    if secondaryPinch { return actions + suspend("손이 움직여 우클릭을 취소했습니다") }
                    state = .dragging; previousPoint = palm; residual = .zero
                    let excess = delta * ((delta.length - configuration.dragThreshold) / delta.length)
                    cursor = (cursor + excess).clamped(width: width, height: height)
                    actions.append(.drag(cursor)); reason = "드래그 중 · 놓으면 완료"
                }
            } else if state == .dragging { actions += move(palm, dragging: true, interval: frameInterval) }
        case .scrolling:
            if hand.isPointer, !pinchLatched {
                previousPoint = resetPointer(hand, at: time)
                previousScroll = nil; scrollStart = nil; residual = .zero
                state = .pointer; reason = "검지를 움직이세요 · 핀치로 클릭"
                return actions
            }
            guard hand.isScroll, !pinchLatched else {
                return actions + suspend("스크롤 종료 · 검지를 펴서 재개하세요")
            }
            if let previousScroll {
                let amount = (palm.y - previousScroll.y) * height * configuration.scrollMultiplier * 2
                if abs(amount) > 0.001 { actions.append(.scroll(amount)) }
            }
            previousScroll = palm
        }
        return actions
    }

    private func scaled(_ delta: Point) -> Point {
        Point(delta.x * width, delta.y * height) * configuration.sensitivity
    }

    private mutating func resetPointer(_ hand: HandFeatures, at time: Double) -> Point {
        filter.reset(); palmFilter.reset()
        let index = filter.update(hand.index, at: time)
        let palm = palmFilter.update(hand.palm, at: time)
        return configuration.controlStyle == .comfortable ? palm : index
    }

    private mutating func move(_ point: Point, dragging: Bool, interval: Double) -> [InputIntent] {
        defer { previousPoint = point }
        guard let previousPoint else { return [] }
        let delta = point - previousPoint
        var gain = 1.0
        if configuration.controlStyle == .comfortable && !dragging {
            // Gain depends on hand speed, not frame rate or display resolution.
            let speed = delta.length / max(0.001, interval)
            let t = min(1, max(0, (speed - 0.025) / 0.195))
            gain = 0.4 + 1.4 * t * t * (3 - 2 * t)
        }
        residual = residual + scaled(delta) * gain
        guard residual.length >= 0.65 else { return [] }
        let next = (cursor + residual).clamped(width: width, height: height)
        residual = .zero
        guard next != cursor else { return [] }
        cursor = next
        return [dragging ? .drag(cursor) : .move(cursor)]
    }

    private mutating func suspend(_ reason: String) -> [InputIntent] {
        let actions: [InputIntent] = buttonDown ? [.up(cursor)] : []
        buttonDown = false; state = .suspended; self.reason = reason; progress = 0
        activationStart = nil; candidateStart = nil; scrollStart = nil; pinchLatched = false; secondaryPinch = false
        uncertainPoseStart = nil
        previousPoint = nil; pressPalm = nil; previousScroll = nil; residual = .zero
        filter.reset(); palmFilter.reset(); recovering = false
        return actions
    }
}
