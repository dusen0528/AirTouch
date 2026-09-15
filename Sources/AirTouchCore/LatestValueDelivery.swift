import Foundation

/// Deliver capture results to a consumer queue without replaying an old backlog.
// The scheduler must enqueue onto one serial consumer queue. Mutable mailbox
// state is locked; the consumer runs only on that queue.
public final class LatestValueDelivery<Value: Sendable>: @unchecked Sendable {
    private let schedule: (@escaping @Sendable () -> Void) -> Void
    private let consume: (Value) -> Void

    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private var replacements = 0
    public var replacedCount: Int { lock.lock(); defer { lock.unlock() }; return replacements }
    public func resetStatistics() { lock.lock(); replacements = 0; lock.unlock() }

    public init(schedule: @escaping (@escaping @Sendable () -> Void) -> Void, consume: @escaping (Value) -> Void) {
        self.schedule = schedule; self.consume = consume
    }

    public func submit(_ value: Value) {
        lock.lock()
        if latest != nil { replacements += 1 }
        latest = value
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { schedule { [weak self] in self?.drain() } }
    }

    private func drain() {
        lock.lock()
        let value = latest
        latest = nil; scheduled = false
        lock.unlock()
        if let value { consume(value) }
    }
}
