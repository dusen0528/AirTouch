import XCTest
@testable import AirTouchCore

final class LatestValueDeliveryTests: XCTestCase {
    func testBusyConsumerReceivesOnlyNewestFrameWithoutGrowingQueue() {
        var scheduled: [() -> Void] = []
        var received: [Int] = []
        let delivery = LatestValueDelivery<Int>(schedule: { scheduled.append($0) }, consume: { received.append($0) })
        for frame in 1...100 { delivery.submit(frame) }
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(received, [100])
        delivery.submit(101)
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(received, [100, 101])
    }

    func testFrameArrivingDuringConsumptionGetsItsOwnDelivery() {
        var scheduled: [() -> Void] = []
        var received: [Int] = []
        var delivery: LatestValueDelivery<Int>!
        delivery = LatestValueDelivery(schedule: { scheduled.append($0) }, consume: { frame in
            received.append(frame)
            if frame == 1 { delivery.submit(2); delivery.submit(3) }
        })
        delivery.submit(1); scheduled.removeFirst()()
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(received, [1, 3])
    }
}
