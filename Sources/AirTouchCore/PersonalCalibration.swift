import Foundation

/// Only aggregate measurements and bounded settings are persisted. Camera
/// coordinates remain inside the running session and are cleared on every exit.
public struct PersonalCalibrationProfile: Codable, Equatable, Sendable {
    public let version: Int
    public let createdAt: Date
    public let sensitivity: Double
    public let minimumCutoff: Double
    public let pinchEnter: Double
    public let pinchExit: Double
    /// Normalized palm displacement used to distinguish pinching from dragging.
    public let dragTolerance: Double
    public let steadyNoise: Double
    public let horizontalRange: Double
    public let verticalRange: Double
    public let pinchOpenRatio: Double
    public let pinchClosedRatio: Double
    public let pinchCycles: Int
    public let acceptedSamples: Int
    public let observedSeconds: Double

    public var isValid: Bool {
        version == 1 && createdAt.timeIntervalSinceReferenceDate.isFinite
            && (1.2...3.2).contains(sensitivity) && (1.0...2.4).contains(minimumCutoff)
            && (0.18...0.42).contains(pinchEnter) && (0.28...0.65).contains(pinchExit)
            && pinchExit - pinchEnter >= 0.099 && (0.008...0.025).contains(dragTolerance)
            && (0...0.018).contains(steadyNoise)
            && (0.14...1).contains(horizontalRange) && (0.12...1).contains(verticalRange)
            && (0.50...2.5).contains(pinchOpenRatio) && (0...0.39).contains(pinchClosedRatio)
            && pinchOpenRatio - pinchClosedRatio >= 0.18
            && pinchEnter >= pinchClosedRatio + 0.025 && pinchExit < pinchOpenRatio
            && pinchCycles == 3 && acceptedSamples >= 285
            && observedSeconds.isFinite && observedSeconds >= 24
    }
}

public enum PersonalCalibrationStage: String, Sendable {
    case idle, steady, horizontal, vertical, pinch, completed, failed, cancelled
    public var isCollecting: Bool {
        self == .steady || self == .horizontal || self == .vertical || self == .pinch
    }
}

public enum PersonalCalibrationFailure: String, Sendable {
    case insufficientSamples, handWasMoving, insufficientHorizontalRange
    case insufficientVerticalRange, indistinctPinches

    public var message: String {
        switch self {
        case .insufficientSamples: return "손을 충분히 관측하지 못했습니다. 손 전체가 보이는 위치에서 다시 해주세요."
        case .handWasMoving: return "정지 단계에서 손이 많이 움직였습니다. 편한 자세에서 잠시 멈추고 다시 해주세요."
        case .insufficientHorizontalRange: return "좌우 움직임을 충분히 구분하지 못했습니다. 처음 위치의 양쪽으로 편하게 움직여주세요."
        case .insufficientVerticalRange: return "위아래 움직임을 충분히 구분하지 못했습니다. 처음 위치의 위와 아래로 움직여주세요."
        case .indistinctPinches: return "집기와 펼치기의 차이가 작거나 세 번을 확인하지 못했습니다. 엄지와 검지를 잘 보이게 하고 다시 해주세요."
        }
    }
}

public enum PersonalCalibrationObservation: String, Sendable {
    case waitingForCamera, searchingHand, adjustHand, pointIndex, showThumb, staleFrame, collecting
}

public struct PersonalCalibrationSnapshot: Sendable {
    public let stage: PersonalCalibrationStage
    public let instruction: String
    public let stageProgress: Double
    public let progress: Double
    public let acceptedSamples: Int
    public let rejectedSamples: Int
    public let pinchCount: Int
    public let failure: PersonalCalibrationFailure?
    public let observation: PersonalCalibrationObservation
    public let retryReason: PersonalCalibrationFailure?
    public let retryCount: Int
    public let pinchHoldProgress: Double
}

/// Camera-driven calibration: 4 s at rest, 7 s horizontally, 7 s vertically,
/// then three open/closed/open pinch cycles over at least 6 s. Missing frames
/// do not contribute time. A caller must use practice output while collecting.
public struct PersonalCalibrationSession {
    public private(set) var stage: PersonalCalibrationStage = .idle
    public private(set) var profile: PersonalCalibrationProfile?
    public private(set) var failure: PersonalCalibrationFailure?
    private var createdAt = Date(timeIntervalSince1970: 0)
    private var stageStartedAt = 0.0
    private var attemptStartedAt: Double?
    private var lastCapture: Double?
    private var lastFreshFrameAt: Double?
    private var lastAcceptedCapture: Double?
    private var stageSeconds = 0.0
    private var totalSeconds = 0.0
    private var completedSamples = 0
    private var acceptedSamples = 0
    private var rejectedSamples = 0
    private var stageSamples: [HandFeatures] = []
    private var feedback: String?
    private var observation: PersonalCalibrationObservation = .waitingForCamera
    private var retryReason: PersonalCalibrationFailure?
    private var retryCount = 0
    private var neutral = Point.zero
    private var steadyNoise = 0.0
    private var horizontalRange = 0.0
    private var verticalRange = 0.0
    private enum PinchPhase { case opening, closing, releasing, done }
    private var pinchPhase = PinchPhase.opening
    private var plateau: [(ratio: Double, palm: Point)] = []
    private var plateauSeconds = 0.0
    private var openRatios: [Double] = []
    private var closedRatios: [Double] = []
    private var pinchShifts: [Double] = []
    private var openAnchor = Point.zero
    private var openRatio = 0.0
    private var pinchCount = 0
    private var pendingOpenRatios: [Double] = []
    private var pendingClosedRatios: [Double] = []
    private var pendingPinchShift = 0.0
    private let pinchGapTolerance = 0.15

    public init() {}

    public mutating func start(at time: Double, date: Date = Date()) {
        self = PersonalCalibrationSession()
        guard time.isFinite, date.timeIntervalSinceReferenceDate.isFinite else {
            fail(.insufficientSamples); return
        }
        createdAt = date
        enter(.steady, at: time)
    }

    public mutating func cancel() {
        self = PersonalCalibrationSession()
        stage = .cancelled
    }

    public mutating func reset() { self = PersonalCalibrationSession() }

    public var snapshot: PersonalCalibrationSnapshot {
        let duration = requiredSeconds
        let phaseProgress = stage == .pinch
            ? min(stageSeconds / duration, Double(pinchCount) / 3)
            : stageSeconds / duration
        let offset: Double
        switch stage {
        case .steady: offset = 0
        case .horizontal: offset = 1
        case .vertical: offset = 2
        case .pinch: offset = 3
        case .completed: offset = 4
        default: offset = 0
        }
        let local = clamp(phaseProgress, 0, 1)
        return PersonalCalibrationSnapshot(stage: stage, instruction: feedback ?? instruction,
            stageProgress: stage == .completed ? 1 : local,
            progress: min(1, (offset + local) / 4), acceptedSamples: acceptedSamples,
            rejectedSamples: rejectedSamples, pinchCount: pinchCount, failure: failure,
            observation: observation, retryReason: retryReason, retryCount: retryCount,
            pinchHoldProgress: stage == .pinch
                ? (pinchPhase == .done ? 1 : min(1, min(Double(plateau.count) / 5, plateauSeconds / 0.15))) : 0)
    }

    /// `confidenceQualified` must reflect reliable palm/index landmarks and,
    /// during the pinch stage, the thumb. Movement calibration does not require
    /// a visible thumb; HandFeatures separately indicates pinch reliability.
    public mutating func update(_ hand: HandFeatures?, capturedAt time: Double,
                                now: Double, confidenceQualified: Bool) {
        guard stage.isCollecting else { return }
        tick(at: now)
        guard stage.isCollecting else { return }
        guard time.isFinite, now.isFinite, time >= stageStartedAt, time <= now, now - time < 0.20,
              lastCapture.map({ time > $0 }) ?? true else {
            reject(.staleFrame, "최신 카메라 영상을 기다리고 있습니다", preservePinch: true)
            return
        }
        let cameraInterval = lastCapture.flatMap { $0 >= stageStartedAt ? time - $0 : nil } ?? 0
        // Compare capture timestamps, not delivery time, so camera latency does
        // not shorten the brief occlusion allowance. Missing callbacks never
        // refresh the last accepted capture or advance a pinch phase.
        if stage == .pinch, let lastAcceptedCapture, time - lastAcceptedCapture > pinchGapTolerance {
            restartUnfinishedPinch()
            self.lastAcceptedCapture = nil
        }
        lastCapture = time; lastFreshFrameAt = now
        guard let hand else {
            reject(.searchingHand, "손을 카메라에 보여주세요. 손목과 검지가 화면 안에 들어오게 해주세요", preservePinch: true)
            return
        }
        guard hand.isValid,
              (0...1).contains(hand.palm.x), (0...1).contains(hand.palm.y),
              (0...1).contains(hand.index.x), (0...1).contains(hand.index.y),
              (0.045...0.8).contains(hand.palmScale), hand.pinchRatio <= 2.5 else {
            reject(.adjustHand, "손 전체가 화면 안에 보이도록 위치를 조정해주세요")
            return
        }
        // A folded thumb may be hidden while the palm and extended index remain
        // reliable. Require it only when its separation is actually measured.
        if stage == .pinch && !hand.isPinchReliable {
            reject(.showThumb, "집는 간격을 확인할 수 있도록 엄지와 검지를 보여주세요", preservePinch: true)
            return
        }
        guard confidenceQualified else {
            reject(.adjustHand, "손바닥과 검지가 선명하게 보이도록 위치와 조명을 조정해주세요", preservePinch: true)
            return
        }
        guard !hand.isOpenPalm, !hand.isScroll else {
            reject(.pointIndex, "검지만 펴고 나머지 손가락은 편하게 접어주세요")
            return
        }
        if stage != .pinch && (!hand.isPointer || hand.pinchRatio < 0.5) {
            reject(.pointIndex, "검지만 펴고 엄지와 간격을 두세요")
            return
        }
        if attemptStartedAt == nil { attemptStartedAt = now }
        lastAcceptedCapture = time
        // Every stage earns time only from fresh, qualified observations.
        // Missing intervals are never bridged by the pinch grace period.
        // The 30 Hz cap deliberately makes lower frame rates take longer.
        let observationTime = cameraInterval > 0 && cameraInterval <= 0.15
            ? min(cameraInterval, 1.0 / 30) : 0
        stageSeconds += observationTime
        acceptedSamples += 1; stageSamples.append(hand); feedback = nil; observation = .collecting
        if stage == .pinch { updatePinch(hand, dt: observationTime) }
        guard stageSeconds >= requiredSeconds else { return }
        switch stage {
        case .steady: finishSteady(at: now)
        case .horizontal: finishRange(horizontal: true, at: now)
        case .vertical: finishRange(horizontal: false, at: now)
        case .pinch:
            if pinchCount == 3 { finishProfile(at: now) }
        default: break
        }
    }

    /// Camera preparation is separate from a measurement attempt. Time alone
    /// can retry an incomplete attempt, but never complete a measurement.
    public mutating func tick(at time: Double) {
        guard stage.isCollecting, time.isFinite else { return }
        let limit = stage == .pinch ? 45.0 : max(20, requiredSeconds * 4)
        if let attemptStartedAt, time - attemptStartedAt >= limit {
            retry(stage == .pinch ? .indistinctPinches : .insufficientSamples, at: time)
        }
        if let lastFreshFrameAt, time - lastFreshFrameAt >= 0.20 {
            observation = .staleFrame
            feedback = "카메라 영상이 잠시 멈췄습니다. 새 영상을 기다리고 있습니다"
        } else if lastFreshFrameAt == nil && time - stageStartedAt >= 8 {
            observation = .staleFrame
            feedback = "카메라 영상이 아직 도착하지 않았습니다. 다른 카메라 앱을 닫고 다시 시작해주세요"
        }
    }

    private var requiredSeconds: Double {
        switch stage {
        case .steady: return 4
        case .horizontal, .vertical: return 7
        case .pinch: return 6
        default: return 1
        }
    }

    private var instruction: String {
        switch stage {
        case .idle: return "카메라로 편한 손 위치와 집는 간격을 맞춥니다. 약 30초 걸립니다."
        case .steady: return "검지만 펴고, 편한 위치에서 손을 잠시 멈추세요"
        case .horizontal: return "검지를 편 채 처음 위치의 왼쪽과 오른쪽으로 천천히 왕복하세요"
        case .vertical: return "검지를 편 채 처음 위치의 위와 아래로 천천히 왕복하세요"
        case .pinch:
            switch pinchPhase {
            case .opening: return "손을 제자리에 두고 엄지와 검지를 벌리세요 · \(pinchCount)/3회"
            case .closing: return "엄지와 검지를 가볍게 집고 잠깐 유지하세요 · \(pinchCount)/3회"
            case .releasing: return "엄지와 검지를 다시 벌리세요 · \(pinchCount)/3회"
            case .done: return "세 번 확인했습니다. 손을 편하게 유지하세요"
            }
        case .completed: return "내 손에 맞는 보정을 마쳤습니다"
        case .failed: return failure?.message ?? "보정을 다시 시작해주세요"
        case .cancelled: return "보정을 취소했습니다"
        }
    }

    private mutating func enter(_ next: PersonalCalibrationStage, at time: Double) {
        stage = next; stageStartedAt = time; stageSeconds = 0; attemptStartedAt = nil
        stageSamples.removeAll(keepingCapacity: true); lastAcceptedCapture = nil
        observation = lastFreshFrameAt == nil ? .waitingForCamera : .collecting
        clearPlateau(); feedback = nil; retryReason = nil
    }

    private mutating func retry(_ reason: PersonalCalibrationFailure, at time: Double) {
        let current = stage
        enter(current, at: time)
        retryReason = reason; retryCount += 1; feedback = reason.message
        if current == .pinch {
            pinchPhase = .opening; pinchCount = 0
            openRatios.removeAll(keepingCapacity: true); closedRatios.removeAll(keepingCapacity: true)
            pinchShifts.removeAll(keepingCapacity: true); openAnchor = .zero; openRatio = 0
            clearPendingPinch()
        }
    }

    private mutating func commitCurrentStage() {
        totalSeconds += stageSeconds
        completedSamples += stageSamples.count
    }

    private mutating func reject(_ state: PersonalCalibrationObservation, _ message: String,
                                 preservePinch: Bool = false) {
        rejectedSamples += 1; observation = state
        // Keep the requested open/close/release instruction visible during a
        // brief dropout; the separate observation label explains the pause.
        feedback = stage == .pinch && preservePinch && lastAcceptedCapture != nil ? nil : message
        if stage != .pinch || !preservePinch {
            lastAcceptedCapture = nil
            if stage == .pinch { restartUnfinishedPinch() }
            else { clearPlateau() }
        }
    }

    private mutating func clearPlateau() { plateau.removeAll(keepingCapacity: true); plateauSeconds = 0 }

    private mutating func clearPendingPinch() {
        pendingOpenRatios.removeAll(keepingCapacity: true)
        pendingClosedRatios.removeAll(keepingCapacity: true)
        pendingPinchShift = 0
    }

    private mutating func restartUnfinishedPinch() {
        clearPlateau(); clearPendingPinch()
        guard pinchPhase != .done else { return }
        pinchPhase = .opening; openAnchor = .zero; openRatio = 0
    }

    private mutating func finishSteady(at time: Double) {
        guard stageSamples.count >= 60 else { retry(.insufficientSamples, at: time); return }
        neutral = center(stageSamples.map(\.palm))
        let radius = stageSamples.map { ($0.palm - neutral).length }
        steadyNoise = quantile(radius, 0.9)
        let ends = max(10, stageSamples.count / 5)
        let drift = (center(stageSamples.prefix(ends).map(\.palm))
            - center(stageSamples.suffix(ends).map(\.palm))).length
        guard steadyNoise <= 0.018, drift <= 0.012 else { retry(.handWasMoving, at: time); return }
        commitCurrentStage()
        enter(.horizontal, at: time)
    }

    private mutating func finishRange(horizontal: Bool, at time: Double) {
        guard stageSamples.count >= 90 else { retry(.insufficientSamples, at: time); return }
        let values = stageSamples.map { horizontal ? $0.palm.x : $0.palm.y }
        let low = quantile(values, 0.05), high = quantile(values, 0.95)
        let origin = horizontal ? neutral.x : neutral.y
        guard high - low >= (horizontal ? 0.14 : 0.12), low <= origin - 0.035,
              high >= origin + 0.035 else {
            retry(horizontal ? .insufficientHorizontalRange : .insufficientVerticalRange, at: time); return
        }
        commitCurrentStage()
        if horizontal {
            horizontalRange = high - low; enter(.vertical, at: time)
        } else {
            verticalRange = high - low; enter(.pinch, at: time)
        }
    }

    private mutating func updatePinch(_ hand: HandFeatures, dt: Double) {
        guard pinchPhase != .done else { return }
        if pinchPhase != .opening && (hand.palm - openAnchor).length >= 0.04 {
            restartUnfinishedPinch()
        }
        if let first = plateau.first, (hand.palm - first.palm).length >= 0.04 { clearPlateau() }
        let qualifies: Bool
        switch pinchPhase {
        case .opening: qualifies = hand.pinchRatio >= 0.5
        case .closing:
            qualifies = hand.pinchRatio <= min(0.39, openRatio - 0.18)
                && (hand.palm - openAnchor).length < 0.04
        case .releasing: qualifies = hand.pinchRatio >= max(0.5, openRatio * 0.75)
        case .done: qualifies = false
        }
        guard qualifies else { clearPlateau(); return }
        if !plateau.isEmpty { plateauSeconds += dt }
        plateau.append((hand.pinchRatio, hand.palm))
        guard plateau.count >= 5, plateauSeconds >= 0.15 else { return }
        let ratios = plateau.map(\.ratio)
        guard quantile(ratios, 0.9) - quantile(ratios, 0.1) <= 0.10 else {
            clearPlateau(); return
        }
        switch pinchPhase {
        case .opening:
            openRatio = quantile(ratios, 0.5); openAnchor = center(plateau.map(\.palm))
            pendingOpenRatios = ratios; pinchPhase = .closing
        case .closing:
            pendingClosedRatios = ratios
            pendingPinchShift = (center(plateau.map(\.palm)) - openAnchor).length
            pinchPhase = .releasing
        case .releasing:
            // Do not learn from a contact unless its release was observed too.
            openRatios += pendingOpenRatios + ratios
            closedRatios += pendingClosedRatios
            pinchShifts.append(pendingPinchShift)
            clearPendingPinch(); pinchCount += 1
            if pinchCount == 3 { pinchPhase = .done }
            else {
                // This confirmed release is the next cycle's open baseline.
                openRatio = quantile(ratios, 0.5); openAnchor = center(plateau.map(\.palm))
                pinchPhase = .closing
            }
        case .done: break
        }
        clearPlateau()
    }

    private mutating func finishProfile(at time: Double) {
        let open = quantile(openRatios, 0.1), closed = quantile(closedRatios, 0.9)
        let gap = open - closed
        guard openRatios.count >= 20, closedRatios.count >= 15, gap >= 0.18 else {
            retry(.indistinctPinches, at: time); return
        }
        let enter = clamp(closed + gap * 0.20, 0.18, 0.42)
        let exit = clamp(closed + gap * 0.55, enter + 0.10, 0.65)
        let result = PersonalCalibrationProfile(version: 1, createdAt: createdAt,
            sensitivity: clamp(0.75 / (min(horizontalRange, verticalRange) * 1.4), 1.2, 3.2),
            minimumCutoff: clamp(2.4 / (1 + steadyNoise / 0.004), 1, 2.4),
            pinchEnter: enter, pinchExit: exit,
            dragTolerance: clamp(max(steadyNoise * 3, quantile(pinchShifts, 0.5) * 1.35), 0.008, 0.025),
            steadyNoise: steadyNoise, horizontalRange: horizontalRange, verticalRange: verticalRange,
            pinchOpenRatio: open, pinchClosedRatio: closed, pinchCycles: pinchCount,
            acceptedSamples: completedSamples + stageSamples.count, observedSeconds: totalSeconds + stageSeconds)
        guard result.isValid else { retry(.indistinctPinches, at: time); return }
        profile = result; stage = .completed; feedback = nil; retryReason = nil; discardSamples()
    }

    private mutating func fail(_ reason: PersonalCalibrationFailure) {
        failure = reason; stage = .failed; profile = nil; feedback = nil; discardSamples()
    }

    private mutating func discardSamples() {
        stageSamples.removeAll(); plateau.removeAll(); openRatios.removeAll(); closedRatios.removeAll()
        clearPendingPinch()
        pinchShifts.removeAll(); neutral = .zero; openAnchor = .zero
        lastAcceptedCapture = nil; lastCapture = nil
    }
}

private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(high, max(low, value))
}

private func quantile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted(), index = Double(values.count - 1) * fraction
    let lower = Int(index), upper = min(lower + 1, values.count - 1)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - Double(lower))
}

private func center(_ points: [Point]) -> Point {
    Point(quantile(points.map(\.x), 0.5), quantile(points.map(\.y), 0.5))
}
