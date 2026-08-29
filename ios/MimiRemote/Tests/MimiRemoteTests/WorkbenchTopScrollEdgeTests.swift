import SwiftUI
import XCTest
@testable import MimiRemote

@MainActor
final class WorkbenchTopScrollEdgeTests: XCTestCase {
    func testBoostStaysOffUntilContentUnderlapsNavigationLayer() {
        // 静止时（贴顶、或列表不足一屏而停在负 inset 上）加深层必须完全不画。
        XCTAssertEqual(WorkbenchTopScrollEdgeBoostRamp.intensity(forUnderlap: 0), 0)
        XCTAssertEqual(WorkbenchTopScrollEdgeBoostRamp.intensity(forUnderlap: -120), 0)

        let ramp = WorkbenchTopScrollEdgeBoostRamp.rampDistance
        let midway = WorkbenchTopScrollEdgeBoostRamp.intensity(forUnderlap: ramp / 2)
        XCTAssertGreaterThan(midway, 0)
        XCTAssertLessThan(midway, 1)
        XCTAssertEqual(WorkbenchTopScrollEdgeBoostRamp.intensity(forUnderlap: ramp), 1)
        XCTAssertEqual(WorkbenchTopScrollEdgeBoostRamp.intensity(forUnderlap: ramp * 40), 1)
        XCTAssertEqual(WorkbenchTopScrollEdgeBoostRamp.intensity(forUnderlap: 1), 0)

        // 量化保证整条 ramp 的状态更新次数有上界，滚动时不会每帧重绘顶部材质。
        let distinctValues = Set(
            stride(from: CGFloat(0), through: ramp, by: 0.5)
                .map { WorkbenchTopScrollEdgeBoostRamp.intensity(forUnderlap: $0) }
        )
        XCTAssertLessThanOrEqual(
            distinctValues.count,
            Int(WorkbenchTopScrollEdgeBoostRamp.intensitySteps) + 1
        )
    }

    func testCoordinatorRejectsStaleProducerUpdatesAndOnlyClearsTheCurrentProducer() {
        let coordinator = WorkbenchTopScrollEdgeCoordinator()
        let previousProducer = UUID()
        let currentProducer = UUID()
        let previousSample = WorkbenchTopScrollEdgeSample(intensity: 1, topInset: 96)
        let currentSample = WorkbenchTopScrollEdgeSample(intensity: 0.5, topInset: 88)
        let staleSample = WorkbenchTopScrollEdgeSample(intensity: 0.25, topInset: 72)

        coordinator.activateProducer(previousProducer, sample: previousSample)
        coordinator.activateProducer(currentProducer, sample: currentSample)
        // 新会话出现后，旧会话可能先收到几何回调再消失；两步都不能覆盖新会话。
        coordinator.publish(staleSample, from: previousProducer)
        coordinator.removeProducer(previousProducer)
        XCTAssertEqual(coordinator.sample, currentSample)

        coordinator.removeProducer(currentProducer)
        XCTAssertEqual(coordinator.sample, WorkbenchTopScrollEdgeSample())
    }
}
