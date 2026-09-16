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

public struct PersonalCalibrationSnapshot: Sendable {
    public let stage: PersonalCalibrationStage
    public let instruction: String
    public let stageProgress: Double
    public let progress: Double
    public let acceptedSamples: Int
    public let rejectedSamples: Int
    public let pinchCount: Int
    public let failure: PersonalCalibrationFailure?
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
    private var lastCapture: Double?
    private var lastAcceptedCapture: Double?
    private var stageSeconds = 0.0
    private var totalSeconds = 0.0
    private var acceptedSamples = 0
    private var rejectedSamples = 0
    private var stageSamples: [HandFeatures] = []
    private var feedback: String?
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
            rejectedSamples: rejectedSamples, pinchCount: pinchCount, failure: failure)
    }

    /// `confidenceQualified` must reflect reliable required palm/index/ thumb
    /// landmarks, not a guessed confidence. HandFeatures cannot carry that fact.
    public mutating func update(_ hand: HandFeatures?, capturedAt time: Double,
                                now: Double, confidenceQualified: Bool) {
        guard stage.isCollecting else { return }
        tick(at: now)
        guard stage.isCollecting else { return }
        guard time.isFinite, now.isFinite, time >= stageStartedAt, time <= now, now - time < 0.20,
              lastCapture.map({ time > $0 }) ?? true else {
            reject("최신 카메라 영상을 기다리고 있습니다")
            return
        }
        lastCapture = time
        guard confidenceQualified, let hand, hand.isValid, hand.isPinchReliable,
              (0...1).contains(hand.palm.x), (0...1).contains(hand.palm.y),
              (0...1).contains(hand.index.x), (0...1).contains(hand.index.y),
              (0.045...0.8).contains(hand.palmScale), hand.pinchRatio <= 2.5,
              !hand.isOpenPalm, !hand.isScroll else {
            reject("손 전체와 엄지·검지가 보이도록 해주세요")
            return
        }
        if stage != .pinch && (!hand.isPointer || hand.pinchRatio < 0.5) {
            reject("검지만 펴고 엄지와 간격을 두세요")
            return
        }
        let interval = lastAcceptedCapture.map { time - $0 } ?? 0
        let dt = interval > 0 && interval <= 0.15 ? interval : 0
        if dt == 0 { clearPlateau() }
        lastAcceptedCapture = time
        stageSeconds += dt; totalSeconds += dt
        acceptedSamples += 1; stageSamples.append(hand); feedback = nil
        if stage == .pinch { updatePinch(hand, dt: dt) }
        guard stageSeconds >= requiredSeconds else { return }
        switch stage {
        case .steady: finishSteady(at: now)
        case .horizontal: finishRange(horizontal: true, at: now)
        case .vertical: finishRange(horizontal: false, at: now)
        case .pinch:
            if pinchCount == 3 { finishProfile() }
        default: break
        }
    }

    /// Called by the UI timer too: elapsed wall time may fail a stage, but can
    /// never complete one when no fresh, confidence-qualified frames arrived.
    public mutating func tick(at time: Double) {
        guard stage.isCollecting, time.isFinite else { return }
        let limit = stage == .pinch ? 45.0 : max(20, requiredSeconds * 4)
        if time - stageStartedAt >= limit {
            fail(stage == .pinch && acceptedSamples > 0 ? .indistinctPinches : .insufficientSamples)
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
        stage = next; stageStartedAt = time; stageSeconds = 0
        stageSamples.removeAll(keepingCapacity: true); lastAcceptedCapture = nil
        clearPlateau(); feedback = nil
    }

    private mutating func reject(_ message: String) {
        rejectedSamples += 1; feedback = message; lastAcceptedCapture = nil; clearPlateau()
    }

    private mutating func clearPlateau() { plateau.removeAll(keepingCapacity: true); plateauSeconds = 0 }

    private mutating func finishSteady(at time: Double) {
        guard stageSamples.count >= 60 else { fail(.insufficientSamples); return }
        neutral = center(stageSamples.map(\.palm))
        let radius = stageSamples.map { ($0.palm - neutral).length }
        steadyNoise = quantile(radius, 0.9)
        let ends = max(10, stageSamples.count / 5)
        let drift = (center(stageSamples.prefix(ends).map(\.palm))
            - center(stageSamples.suffix(ends).map(\.palm))).length
        guard steadyNoise <= 0.018, drift <= 0.012 else { fail(.handWasMoving); return }
        enter(.horizontal, at: time)
    }

    private mutating func finishRange(horizontal: Bool, at time: Double) {
        guard stageSamples.count >= 90 else { fail(.insufficientSamples); return }
        let values = stageSamples.map { horizontal ? $0.palm.x : $0.palm.y }
        let low = quantile(values, 0.05), high = quantile(values, 0.95)
        let origin = horizontal ? neutral.x : neutral.y
        guard high - low >= (horizontal ? 0.14 : 0.12), low <= origin - 0.035,
              high >= origin + 0.035 else {
            fail(horizontal ? .insufficientHorizontalRange : .insufficientVerticalRange); return
        }
        if horizontal {
            horizontalRange = high - low; enter(.vertical, at: time)
        } else {
            verticalRange = high - low; enter(.pinch, at: time)
        }
    }

    private mutating func updatePinch(_ hand: HandFeatures, dt: Double) {
        guard pinchPhase != .done else { return }
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
            openRatios += ratios; pinchPhase = .closing
        case .closing:
            closedRatios += ratios
            pinchShifts.append((center(plateau.map(\.palm)) - openAnchor).length)
            pinchPhase = .releasing
        case .releasing:
            openRatios += ratios; pinchCount += 1
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

    private mutating func finishProfile() {
        let open = quantile(openRatios, 0.1), closed = quantile(closedRatios, 0.9)
        let gap = open - closed
        guard openRatios.count >= 20, closedRatios.count >= 15, gap >= 0.18 else {
            fail(.indistinctPinches); return
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
            acceptedSamples: acceptedSamples, observedSeconds: totalSeconds)
        guard result.isValid else { fail(.indistinctPinches); return }
        profile = result; stage = .completed; feedback = nil; discardSamples()
    }

    private mutating func fail(_ reason: PersonalCalibrationFailure) {
        failure = reason; stage = .failed; profile = nil; feedback = nil; discardSamples()
    }

    private mutating func discardSamples() {
        stageSamples.removeAll(); plateau.removeAll(); openRatios.removeAll(); closedRatios.removeAll()
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
