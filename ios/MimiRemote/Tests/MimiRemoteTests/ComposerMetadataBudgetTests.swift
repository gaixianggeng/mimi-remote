import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// 真机打开会话即崩溃（#852）和输入框占栈过多（#869）的回归防线。
///
/// 真机主线程栈约 1 MB，模拟器是 8 MB，栈溢出在模拟器和 CI 上复现不了。这里直接约束
/// 决定栈用量的两项类型指标（原因见 ComposerErasedControls.swift）：
/// - 值大小：构建 `some View` 的函数，栈帧约是修饰链上各中间值大小之和，所以 body 和它的每一段都按值大小设预算；
/// - 组合类型的嵌套层数：解析泛型元数据时逐层递归，每层约 3 KB。
///
/// 预算按 iPad mini（iPadOS 27.2）上验证过的版本设定，只留少量余量：
/// - #869 分段擦除后 Body 968 B / 23 层，最大一段（VStack 内容）7 032 B；进入 body 时已用 79 KB，
///   输入框路径峰值宽屏 205 KB、竖屏 196 KB，打开会话的全局峰值已不在输入框路径上；
/// - 分段前 Body 11 776 B / 90 层，body 单帧 412 KB，进入 body 时已用 481 KB、峰值 593 KB；
/// - #838 合并后的 main 是 Body 21 480 B / 109 层、输入行 42 层，进入 body 时已用 878 KB 并崩溃。
/// 超出预算时先把新控件或修饰符放进 ComposerErasedControls.swift 擦除，再在真机上用种子会话
/// 打开一次确认，不要直接调大预算。
@MainActor
final class ComposerMetadataBudgetTests: XCTestCase {
    func testTypeMetricsParseNestedGenericNames() {
        let metrics = ViewTypeMetrics(
            ModifiedContent<HStack<TupleView<(Text, Optional<Text>)>>, _PaddingLayout>.self
        )

        // ModifiedContent → HStack → TupleView → 元组 → Optional：解析失效时预算会形同虚设。
        XCTAssertEqual(metrics.depth, 5, metrics.summary("fixture"))
        XCTAssertEqual(ViewTypeMetrics.nestingDepth(of: "Swift.Optional<(Swift.Int) -> Swift.String>"), 2)
    }

    func testComposerBodyStaysWithinDeviceStackBudget() {
        let metrics = ViewTypeMetrics(ComposerView.Body.self)

        // body 只在最后一段 AnyView 上挂生命周期修饰符；层数过低说明 opaque 类型没有展开，预算会形同虚设。
        XCTAssertGreaterThan(metrics.depth, 12, metrics.summary("ComposerView.Body"))
        XCTAssertLessThanOrEqual(metrics.size, 1280, metrics.summary("ComposerView.Body"))
        XCTAssertLessThanOrEqual(metrics.depth, 28, metrics.summary("ComposerView.Body"))
    }

    func testComposerBodySegmentsStayWithinDeviceStackBudget() {
        // 每段在自己的盒子里构建，栈帧约是段内中间值大小之和；直接往 body 加修饰符或子视图也会落到这里。
        let segments = [
            ("composerPresentedContent", ViewTypeMetrics.result(of: ComposerView.composerPresentedContent), 8 * 1024, 32),
            ("composerPresentations", ViewTypeMetrics.result(of: ComposerView.composerPresentations), 3 * 1024, 16),
            ("composerScopeObservers", ViewTypeMetrics.result(of: ComposerView.composerScopeObservers), 1024, 24),
            ("composerDraftObservers", ViewTypeMetrics.result(of: ComposerView.composerDraftObservers), 1024, 16),
        ]

        for (label, metrics, sizeBudget, depthBudget) in segments {
            XCTAssertLessThanOrEqual(metrics.size, sizeBudget, metrics.summary(label))
            XCTAssertLessThanOrEqual(metrics.depth, depthBudget, metrics.summary(label))
        }
    }

    func testComposerInputRowOnlyHoldsErasedCards() {
        let metrics = ViewTypeMetrics.result(of: ComposerView.composerInputRow)

        XCTAssertLessThanOrEqual(metrics.size, 1024, metrics.summary("composerInputRow"))
        XCTAssertLessThanOrEqual(metrics.depth, 16, metrics.summary("composerInputRow"))
    }

    func testComposerToolbarsOnlyHoldErasedControls() {
        // 宽档与紧凑档两条分支都在这个类型里；任一分支直接平铺 Menu 都会超过预算。
        let metrics = ViewTypeMetrics.value(of: \ComposerView.primaryComposerToolbar)

        XCTAssertLessThanOrEqual(metrics.depth, 8, metrics.summary("primaryComposerToolbar"))
    }

    func testComposerCardsStayWithinMetadataDepthBudget() {
        let cards = [
            ("composerCard", ViewTypeMetrics.result(of: ComposerView.composerCard)),
            ("phoneComposerCard", ViewTypeMetrics.result(of: ComposerView.phoneComposerCard)),
            ("collapsedIPadComposerCard", ViewTypeMetrics.result(of: ComposerView.collapsedIPadComposerCard)),
        ]

        for (label, metrics) in cards {
            XCTAssertLessThanOrEqual(metrics.depth, 32, metrics.summary(label))
        }
    }

    /// 擦除边界常包着带条件的控件（投递方式、上下文圆环）；空内容必须和 `if` 一样不占栈间距。
    func testErasedEmptyControlTakesNoStackSpacing() {
        let toolbar = HStack(spacing: 10) {
            Color.clear.frame(width: 20, height: 20)
            AnyView(Optional<Text>.none)
            Color.clear.frame(width: 20, height: 20)
        }

        let size = UIHostingController(rootView: toolbar)
            .sizeThatFits(in: CGSize(width: 500, height: 100))

        XCTAssertEqual(size.width, 50, accuracy: 0.5)
    }
}

/// 组合类型的嵌套层数与值大小。嵌套层数按完整类型名的尖括号和元组括号计算，
/// 与运行时递归解析泛型实参的深度一致；opaque 返回类型在这里已经展开成实际类型。
/// 输入框与工作台壳层（WorkbenchShellMetadataBudgetTests）的栈预算共用。
struct ViewTypeMetrics {
    let name: String
    let size: Int
    let depth: Int

    init<T>(_ type: T.Type) {
        name = String(reflecting: type)
        size = MemoryLayout<T>.size
        depth = Self.nestingDepth(of: name)
    }

    static func result<Receiver, Argument, Result>(
        of method: (Receiver) -> (Argument) -> Result
    ) -> Self {
        Self(Result.self)
    }

    static func value<Root, Value>(of keyPath: KeyPath<Root, Value>) -> Self {
        Self(Value.self)
    }

    static func nestingDepth(of name: String) -> Int {
        var depth = 0
        var maxDepth = 0
        var previous: Character?
        for character in name {
            switch character {
            case "<", "(":
                depth += 1
                maxDepth = max(maxDepth, depth)
            case ">" where previous != "-", ")":
                depth -= 1
            default:
                break
            }
            previous = character
        }
        return maxDepth
    }

    func summary(_ label: String) -> String {
        "\(label) depth=\(depth) size=\(size)B"
    }
}
