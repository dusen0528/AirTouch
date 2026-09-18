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

/// A disabled output lease. Tracking loss can reacquire through the controller;
/// permission loss requires an explicit restart after permission is restored.
struct SystemInputInterruption: Equatable, Sendable {
    enum Cause: String, Sendable {
        case trackingTimeout
        case permissionRevoked
    }
    let generation: Int
    let leaseID: UInt64
    let cause: Cause
}

final class SystemInputDispatcher {
    static let eventTag: Int64 = 0x416972546F756368
    private let queue = DispatchQueue(label: "airtouch.system-output", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let clock: () -> Double
    private let permissionCheck: () -> Bool
    private let postSink: (([InputIntent]) -> Void)?
    private var gate = SystemOutputGate()
    private var leaseID: UInt64 = 0
    private var currentInterruption: SystemInputInterruption?
    private var area = DisplayArea(origin: .zero, width: 1, height: 1)
    private lazy var eventSource = CGEventSource(stateID: .privateState)
    private var timer: DispatchSourceTimer?
    private var scrollRemainder = 0.0
    private var clickCount: Int64 = 1
    private var lastClickTime = -Double.infinity
    private var lastClickPosition = Point.zero
    private var dragged = false
    private var doubleClickInterval = 0.5
    /// Called once on the output queue, after any held button has been released.
    /// Consumers dispatch to their owner and check isCurrent before recovery.
    var onInterruption: ((SystemInputInterruption) -> Void)?
    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         permissionCheck: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         postSink: (([InputIntent]) -> Void)? = nil, watchdogEnabled: Bool = true) {
        self.clock = clock; self.permissionCheck = permissionCheck; self.postSink = postSink
        queue.setSpecific(key: queueKey, value: true)
        guard watchdogEnabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.03, repeating: 0.03)
        timer.setEventHandler { [weak self] in self?.watchdogStep() }
        self.timer = timer; timer.resume()
    }

    deinit { timer?.cancel() }

    /// Runs the timer's production path deterministically without posting input
    /// when a diagnostic sink was supplied.
    func checkWatchdog() { sync { watchdogStep() } }

    /// Permission restoration alone never revives a disabled lease.
    func isCurrent(_ interruption: SystemInputInterruption) -> Bool {
        sync { !gate.active && currentInterruption == interruption }
    }

    private func watchdogStep() {
        guard gate.active else { return }
        let lease = leaseID
        let permitted = permissionCheck()
        let actions = gate.expire(now: clock(), permitted: permitted)
        post(actions, releaseAt: releasePosition())
        notifyInterruption(wasActive: true, lease: lease, permitted: permitted)
    }

    private func notifyInterruption(wasActive: Bool, lease: UInt64, permitted: Bool) {
        guard wasActive, !gate.active, leaseID == lease, currentInterruption == nil else { return }
        let interruption = SystemInputInterruption(generation: gate.generation, leaseID: lease,
            cause: permitted ? .trackingTimeout : .permissionRevoked)
        currentInterruption = interruption
        onInterruption?(interruption)
    }

    private func sync<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return work() }
        return queue.sync(execute: work)
    }

    private func releasePosition() -> CGPoint? {
        postSink == nil ? CGEvent(source: nil)?.location : nil
    }

    func begin(generation: Int, area: DisplayArea, position: Point, doubleClickInterval: Double) {
        sync {
            leaseID &+= 1; currentInterruption = nil
            post(gate.stop(), releaseAt: releasePosition())
            self.area = area; self.doubleClickInterval = doubleClickInterval
            scrollRemainder = 0; lastClickTime = -.infinity; dragged = false
            _ = gate.begin(generation: generation, position: position, now: clock())
        }
    }

    func frame(generation: Int, capturedAt: Double, validHand: Bool, intents: [InputIntent]) {
        queue.async { [weak self] in
            guard let self else { return }
            let wasActive = self.gate.active
            let lease = self.leaseID
            let now = self.clock()
            let permitted = self.permissionCheck()
            self.gate.heartbeat(generation: generation, capturedAt: capturedAt, validHand: validHand, now: now)
            let actions = self.gate.accept(intents, generation: generation, now: now, permitted: permitted)
            self.post(actions)
            self.notifyInterruption(wasActive: wasActive, lease: lease, permitted: permitted)
        }
    }

    func release(_ intents: [InputIntent], generation: Int) {
        sync {
            let wasActive = gate.active
            let lease = leaseID
            let permitted = permissionCheck()
            post(gate.accept(intents, generation: generation, now: clock(), permitted: permitted))
            notifyInterruption(wasActive: wasActive, lease: lease, permitted: permitted)
        }
    }

    /// Synchronous: queued frames cannot re-press after an emergency stop.
    func stop() {
        sync {
            leaseID &+= 1; currentInterruption = nil
            post(gate.stop(), releaseAt: releasePosition()); scrollRemainder = 0
        }
    }

    private func post(_ intents: [InputIntent], releaseAt: CGPoint? = nil) {
        if let postSink { postSink(intents); return }
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
                    clickCount = !dragged && clock() - lastClickTime <= doubleClickInterval
                        && (p - lastClickPosition).length <= 6 ? min(3, clickCount + 1) : 1
                    dragged = false
                case .drag: type = .leftMouseDragged; dragged = true
                case .up:
                    type = .leftMouseUp; lastClickTime = dragged ? -.infinity : clock(); lastClickPosition = p
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
