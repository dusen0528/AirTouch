import AirTouchCore
import Foundation

/// Development camera measurements exercise the final gate but never post events.
/// Used only by the explicit --camera-benchmark --pipeline-benchmark launch path.
final class BenchmarkInputSink: SystemTrackingInputSink {
    private var gate = SystemOutputGate()
    func begin(generation: Int, area: DisplayArea, position: Point, doubleClickInterval: Double) {
        _ = gate.begin(generation: generation, position: position, now: ProcessInfo.processInfo.systemUptime)
    }
    func frame(generation: Int, capturedAt: Double, validHand: Bool, intents: [InputIntent]) {
        let now = ProcessInfo.processInfo.systemUptime
        gate.heartbeat(generation: generation, capturedAt: capturedAt, validHand: validHand, now: now)
        _ = gate.accept(intents, generation: generation, now: now, permitted: true)
    }
    func release(_ intents: [InputIntent], generation: Int) {
        _ = gate.accept(intents, generation: generation, now: ProcessInfo.processInfo.systemUptime, permitted: true)
    }
    func stop() { _ = gate.stop() }
}
