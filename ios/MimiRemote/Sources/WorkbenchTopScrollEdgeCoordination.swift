import Foundation
import Observation
import SwiftUI

/// 会话列量到的一组顶部边缘参数。两个字段一起走一次回调，避免强度和几何分两拍到达、
/// 在分栏缝上闪出一帧错位。
struct WorkbenchTopScrollEdgeSample: Equatable {
    var intensity: Double = 0
    /// 状态栏 + 导航控制层。取自滚动几何的 `contentInsets.top`，也就是列表真正让出的那段。
    var topInset: CGFloat = 0
}

/// 顶部加深带的跨列协调器。
///
/// 加深带只能画在各自列的内容之上、导航栏之下——SwiftUI 的 toolbar 是按列绘制的，
/// 一条真正横跨整屏的 overlay 会连标题和工具按钮一起蒙住，所以两列各画一段并共享参数。
/// `producerID` 保证转场期间只有当前会话能清理状态，旧会话消失时不会擦掉新会话的数据。
@MainActor
@Observable
final class WorkbenchTopScrollEdgeCoordinator {
    private(set) var sample = WorkbenchTopScrollEdgeSample()
    private var producerID: UUID?

    func activateProducer(_ producerID: UUID, sample: WorkbenchTopScrollEdgeSample) {
        self.producerID = producerID
        self.sample = sample
    }

    func publish(_ sample: WorkbenchTopScrollEdgeSample, from producerID: UUID) {
        // 转场中的旧会话仍可能收到最后一次几何回调，但不能重新夺回新会话的所有权。
        guard self.producerID == producerID else { return }
        self.sample = sample
    }

    func removeProducer(_ producerID: UUID) {
        guard self.producerID == producerID else { return }
        self.producerID = nil
        sample = WorkbenchTopScrollEdgeSample()
    }
}

extension View {
    /// 协调器只服务当前工作台视图树，不进入业务 Shell 的持久状态。
    func workbenchTopScrollEdgeCoordination() -> some View {
        modifier(WorkbenchTopScrollEdgeCoordinationModifier())
    }
}

private struct WorkbenchTopScrollEdgeCoordinationModifier: ViewModifier {
    @State private var coordinator = WorkbenchTopScrollEdgeCoordinator()

    func body(content: Content) -> some View {
        content.environment(coordinator)
    }
}
