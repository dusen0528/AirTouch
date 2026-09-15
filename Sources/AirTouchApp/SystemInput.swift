import AppKit
import ApplicationServices
import AirTouchCore
import Carbon

struct ControlDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let area: DisplayArea
    static func current() -> [ControlDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            let bounds = CGDisplayBounds(id)
            return ControlDisplay(id: id, name: screen.localizedName,
                area: DisplayArea(origin: Point(bounds.minX, bounds.minY), width: bounds.width, height: bounds.height))
        }
    }
}

final class SystemInputDispatcher {
    static let eventTag: Int64 = 0x416972546F756368
    private let queue = DispatchQueue(label: "airtouch.system-output", qos: .userInteractive)
    private var gate = SystemOutputGate()
    private var area = DisplayArea(origin: .zero, width: 1, height: 1)
    private let eventSource = CGEventSource(stateID: .privateState)
    private var timer: DispatchSourceTimer?
    private var scrollRemainder = 0.0
    private var clickCount: Int64 = 1
    private var lastClickTime = -Double.infinity
    private var lastClickPosition = Point.zero
    private var dragged = false
    private var doubleClickInterval = 0.5
    var onFault: ((Int, String) -> Void)?
    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.03, repeating: 0.03)
        timer.setEventHandler { [weak self] in
            guard let self, self.gate.active else { return }
            let generation = self.gate.generation
            let actions = self.gate.expire(now: Self.now, permitted: CGPreflightPostEventAccess())
            self.post(actions, releaseAt: CGEvent(source: nil)?.location)
            if !self.gate.active { self.onFault?(generation, "입력 응답 또는 권한이 끊겨 전체 제어를 멈췄습니다") }
        }
        self.timer = timer; timer.resume()
    }

    deinit { timer?.cancel() }

    func begin(generation: Int, area: DisplayArea, position: Point, doubleClickInterval: Double) {
        queue.sync {
            post(gate.stop(), releaseAt: CGEvent(source: nil)?.location)
            self.area = area; self.doubleClickInterval = doubleClickInterval
            scrollRemainder = 0; lastClickTime = -.infinity; dragged = false
            _ = gate.begin(generation: generation, position: position, now: Self.now)
        }
    }

    func frame(generation: Int, capturedAt: Double, validHand: Bool, intents: [InputIntent]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.gate.heartbeat(generation: generation, capturedAt: capturedAt, validHand: validHand, now: Self.now)
            let actions = self.gate.accept(intents, generation: generation, now: Self.now, permitted: CGPreflightPostEventAccess())
            self.post(actions)
        }
    }

    func release(_ intents: [InputIntent], generation: Int) {
        queue.sync { post(gate.accept(intents, generation: generation, now: Self.now, permitted: CGPreflightPostEventAccess())) }
    }

    /// Synchronous: queued frames cannot re-press after an emergency stop.
    func stop() { queue.sync { post(gate.stop(), releaseAt: CGEvent(source: nil)?.location); scrollRemainder = 0 } }

    private func post(_ intents: [InputIntent], releaseAt: CGPoint? = nil) {
        for intent in intents {
            var event: CGEvent?
            switch intent {
            case .secondaryClick(let point):
                scrollRemainder = 0; lastClickTime = -.infinity
                let p = area.global(point)
                // Allocate both first, then post as one balanced pair on this queue.
                guard let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown,
                    mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: .right),
                      let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp,
                    mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: .right) else { continue }
                for click in [down, up] {
                    click.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
                    click.setIntegerValueField(.mouseEventClickState, value: 1)
                    click.flags = []; click.post(tap: .cghidEventTap)
                }
                continue
            case .move(let point), .down(let point), .drag(let point), .up(let point):
                scrollRemainder = 0
                var p = area.global(point)
                if case .up = intent, let releaseAt { p = Point(releaseAt.x, releaseAt.y) }
                let type: CGEventType
                switch intent {
                case .down:
                    type = .leftMouseDown
                    clickCount = !dragged && Self.now - lastClickTime <= doubleClickInterval
                        && (p - lastClickPosition).length <= 6 ? min(3, clickCount + 1) : 1
                    dragged = false
                case .drag: type = .leftMouseDragged; dragged = true
                case .up:
                    type = .leftMouseUp; lastClickTime = dragged ? -.infinity : Self.now; lastClickPosition = p
                default: type = .mouseMoved
                }
                event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                    mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: .left)
                if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState, value: clickCount) }
            case .scroll(let delta):
                scrollRemainder += max(-300, min(300, -delta)) // No accumulated scroll debt.
                let pixels = Int32(max(-300, min(300, scrollRemainder.rounded(.towardZero))))
                scrollRemainder -= Double(pixels)
                guard pixels != 0 else { continue }
                event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                    wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)
            }
            event?.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// Carbon hotkeys don't require recording keyboard events or Input Monitoring access.
final class EmergencyHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    func register() -> Bool {
        if reference != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            guard GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
                  identity.signature == 0x41725463, identity.id == 1 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<EmergencyHotKey>.fromOpaque(context).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x41725463, id: 1), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        if status != noErr { unregister() }
        return status == noErr
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    deinit { unregister() }
}
