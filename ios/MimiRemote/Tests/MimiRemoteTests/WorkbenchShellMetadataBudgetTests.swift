import SwiftUI
import XCTest
@testable import MimiRemote

/// iPad 宽屏打开会话时工作台壳层占掉约 3/4 主线程栈（#865）的回归防线。
///
/// 真机主线程栈约 1 MB，模拟器是 8 MB，栈压力在模拟器和 CI 上看不出来。这里约束决定栈用量的
/// 类型指标（原因见 WorkbenchShellErasedLayouts.swift）：
/// - GeometryReader 内容的值大小：GeometryReader 闭包、布局分支闭包和 SwiftUI 的泛型帧都随它成比例变大；
/// - 组合类型的嵌套层数：解析泛型元数据时逐层递归。
///
/// 预算按 iPad mini（iPadOS 27.2）上验证过的擦除版设定，只留少量余量：
/// 擦除前 GeometryReader 内容 11 872 B / 71 层、`compactDestination` 7 875 B / 33 层，
/// 宽屏打开会话时壳层路径峰值 754 KB、竖屏 549 KB；擦除后分别是 1 104 B / 31 层、556 B / 4 层。
/// 超出预算时先把新内容放进 WorkbenchShellErasedLayouts.swift 擦除，再在真机上确认，不要直接调大预算。
@MainActor
final class WorkbenchShellMetadataBudgetTests: XCTestCase {
    func testGeometryReaderContentOnlyHoldsErasedLayouts() throws {
        let metrics = try XCTUnwrap(
            Self.geometryReaderContentMetrics(in: UnifiedWorkbenchShell.Body.self),
            "UnifiedWorkbenchShell.body 不再以 GeometryReader 为根时，请同步调整这条防线"
        )

        // 三种布局在 `_ConditionalContent` 里按最大分支占存储；任一分支不经盒子直接返回都会超出。
        XCTAssertLessThanOrEqual(metrics.size, 2 * 1024, metrics.summary("GeometryReader content"))
        XCTAssertLessThanOrEqual(metrics.depth, 40, metrics.summary("GeometryReader content"))
    }

    func testCompactSessionDestinationHoldsErasedDetail() {
        let metrics = Self.resultMetrics(of: UnifiedWorkbenchShell.compactDestination(_:layout:tokens:shouldHideTabBar:))

        // 紧凑导航 push 会话详情与宽屏 detail 列共用 sessionDetailBox；直接返回会话详情约 8 KB。
        XCTAssertLessThanOrEqual(metrics.size, 1024, metrics.summary("compactDestination"))
        XCTAssertLessThanOrEqual(metrics.depth, 8, metrics.summary("compactDestination"))
    }

    /// 沿 `ModifiedContent` 外层修饰器向内找到第一个 GeometryReader，返回它内容类型的指标。
    private static func geometryReaderContentMetrics(in type: Any.Type) -> ViewTypeMetrics? {
        var current = type
        while true {
            if let reader = current as? GeometryReaderContentMeasuring.Type {
                return reader.contentMetrics
            }
            guard let modified = current as? ModifiedContentUnwrapping.Type else {
                return nil
            }
            current = modified.wrappedContentType
        }
    }

    private static func resultMetrics<Receiver, A, B, C, D, Result>(
        of method: (Receiver) -> (A, B, C, D) -> Result
    ) -> ViewTypeMetrics {
        ViewTypeMetrics(Result.self)
    }
}

private protocol ModifiedContentUnwrapping {
    static var wrappedContentType: Any.Type { get }
}

extension ModifiedContent: ModifiedContentUnwrapping {
    fileprivate static var wrappedContentType: Any.Type { Content.self }
}

private protocol GeometryReaderContentMeasuring {
    static var contentMetrics: ViewTypeMetrics { get }
}

extension GeometryReader: GeometryReaderContentMeasuring {
    fileprivate static var contentMetrics: ViewTypeMetrics { ViewTypeMetrics(Content.self) }
}
