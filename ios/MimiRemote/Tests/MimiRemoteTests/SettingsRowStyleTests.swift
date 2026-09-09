import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class SettingsRowStyleTests: XCTestCase {
    func testStandardRowUses52PointMinimumHeight() {
        XCTAssertEqual(measuredHeight(kind: .standard, dynamicTypeSize: .large), 52, accuracy: 0.5)
    }

    func testDescriptiveAndAccessibilityRowsUse76PointMinimumHeight() {
        XCTAssertEqual(measuredHeight(kind: .descriptive, dynamicTypeSize: .large), 76, accuracy: 0.5)
        XCTAssertEqual(measuredHeight(kind: .standard, dynamicTypeSize: .accessibility1), 76, accuracy: 0.5)
    }

    func testLongContentCanGrowBeyondMinimumHeight() {
        let view = Text(String(repeating: "设置说明 ", count: 30))
            .fixedSize(horizontal: false, vertical: true)
            .settingsRow(.descriptive)
            .environment(\.dynamicTypeSize, .accessibility3)

        XCTAssertGreaterThan(measuredHeight(view), 76)
    }

    private func measuredHeight(
        kind: SettingsRowKind,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        measuredHeight(
            Color.clear
                .frame(height: 1)
                .settingsRow(kind)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        )
    }

    private func measuredHeight<V: View>(_ view: V) -> CGFloat {
        let controller = UIHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: 320, height: 2_000)).height
    }
}
