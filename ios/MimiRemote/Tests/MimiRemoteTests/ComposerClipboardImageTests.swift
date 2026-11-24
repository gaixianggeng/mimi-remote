import PencilKit
import XCTest
@testable import MimiRemote

final class ComposerClipboardImageTests: XCTestCase {
    // MARK: - 剪贴板提示

    func testNoticeAppearsOnlyForImagesThatWereNotDismissed() {
        var state = ComposerClipboardImageState(defaults: nil)
        state.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        XCTAssertTrue(state.isVisible)

        state.dismissCurrent()
        XCTAssertFalse(state.isVisible)
        state.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        XCTAssertFalse(state.isVisible, "同一份剪贴板内容关闭或用过后不再出现")

        state.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertTrue(state.isVisible, "复制了新图片后再次出现")
    }

    func testNoticeHiddenForTextOrWhenAttachmentsUnsupported() {
        var state = ComposerClipboardImageState(defaults: nil)
        state.refresh(hasImages: false, changeCount: 3, acceptsImages: true)
        XCTAssertFalse(state.isVisible, "只有文字时不出现")
        state.refresh(hasImages: true, changeCount: 4, acceptsImages: false)
        XCTAssertFalse(state.isVisible, "不收附件的通道（DeepSeek）不出现")
    }

    func testDismissPersistsAcrossStateRecreationUntilClipboardChanges() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var initialState = ComposerClipboardImageState(defaults: defaults)
        initialState.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        XCTAssertTrue(initialState.isVisible)

        initialState.dismissCurrent()
        XCTAssertFalse(initialState.isVisible)

        // 模拟离开会话再重新进入，重建 ComposerView 及其 @State。
        var recreatedState = ComposerClipboardImageState(defaults: defaults)
        recreatedState.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        XCTAssertFalse(recreatedState.isVisible, "重新进入会话后，同一 changeCount 的剪贴板图片不再重复提示")

        recreatedState.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertTrue(recreatedState.isVisible, "剪贴板内容更新为新 changeCount 后再次显示")
    }

    func testDismissPersistsZeroChangeCountAndSurvivesRedundantDismiss() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var initialState = ComposerClipboardImageState(defaults: defaults)
        initialState.refresh(hasImages: true, changeCount: 0, acceptsImages: true)
        XCTAssertTrue(initialState.isVisible)

        initialState.dismissCurrent()
        // 已经关闭后再调一次无参 dismiss，不应抹掉刚持久化的 changeCount。
        initialState.dismissCurrent()

        var recreatedState = ComposerClipboardImageState(defaults: defaults)
        recreatedState.refresh(hasImages: true, changeCount: 0, acceptsImages: true)
        XCTAssertFalse(recreatedState.isVisible, "changeCount 为 0 时也应正确区分未记录与已关闭")

        recreatedState.refresh(hasImages: true, changeCount: 1, acceptsImages: true)
        XCTAssertTrue(recreatedState.isVisible)
    }

    func testDismissWithFallbackChangeCountAndPeerRefreshStaySuppressed() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var stateA = ComposerClipboardImageState(defaults: defaults)
        var stateB = ComposerClipboardImageState(defaults: defaults)

        // 模拟未显示横幅时通过 ⌘V 粘贴直接记录当前 changeCount。
        stateA.dismissCurrent(fallbackChangeCount: 12)

        stateB.refresh(hasImages: true, changeCount: 12, acceptsImages: true)
        XCTAssertFalse(stateB.isVisible, "同套持久化里的已有实例刷新时也应感知已关闭状态")

        var recreatedState = ComposerClipboardImageState(defaults: defaults)
        recreatedState.refresh(hasImages: true, changeCount: 12, acceptsImages: true)
        XCTAssertFalse(recreatedState.isVisible)
        recreatedState.refresh(hasImages: true, changeCount: 13, acceptsImages: true)
        XCTAssertTrue(recreatedState.isVisible)
    }

    func testPreparingCountIsScopedAndBalanced() {
        var state = ComposerClipboardImageState(defaults: nil)
        let scopeA = ComposerDraftScopeKey.none
        state.beginPreparing(scopeA)
        state.beginPreparing(scopeA)
        XCTAssertTrue(state.isPreparing(scopeA))
        state.endPreparing(scopeA)
        XCTAssertTrue(state.isPreparing(scopeA), "两项处理只结束了一项，仍要挡住发送")
        state.endPreparing(scopeA)
        XCTAssertFalse(state.isPreparing(scopeA))
        state.endPreparing(scopeA)
        XCTAssertFalse(state.isPreparing(scopeA), "多结束一次不会变成负数")
        XCTAssertTrue(state.preparingCountByScope.isEmpty)
    }

    func testAnnotationReplacesTheOpenedCopyWhenTheSameImageIsAttachedTwice() {
        let image = CodexAppServerUserInput.image(url: "data:image/png;base64,AAAA", detail: .auto)
        let other = CodexAppServerUserInput.image(url: "data:image/png;base64,BBBB", detail: .auto)
        let attachments = [image, other, image]
        XCTAssertEqual(ComposerView.annotationReplacementIndex(in: attachments, original: image, preferredIndex: 2), 2)
        XCTAssertEqual(ComposerView.annotationReplacementIndex(in: attachments, original: image, preferredIndex: 1), 0, "位置已对不上时退回第一份同内容附件")
        XCTAssertEqual(ComposerView.annotationReplacementIndex(in: attachments, original: image, preferredIndex: 9), 0)
        XCTAssertNil(ComposerView.annotationReplacementIndex(in: [other], original: image, preferredIndex: 0), "原附件已删除时不替换")
    }

    // MARK: - 标注与裁剪

    func testFittedSizeKeepsAspectRatioInsidePadding() {
        let fitted = ImageAnnotationGeometry.fittedSize(CGSize(width: 2000, height: 1000), in: CGSize(width: 432, height: 800), padding: 16)
        XCTAssertEqual(fitted.width, 400)
        XCTAssertEqual(fitted.height, 200)
    }

    func testPixelCropRectClampsToImage() {
        let pixels = CGSize(width: 1000, height: 500)
        XCTAssertEqual(
            ImageAnnotationGeometry.pixelCropRect(normalized: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5), pixelSize: pixels),
            CGRect(x: 100, y: 100, width: 500, height: 250)
        )
        XCTAssertEqual(
            ImageAnnotationGeometry.pixelCropRect(normalized: CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5), pixelSize: pixels),
            CGRect(x: 800, y: 400, width: 200, height: 100),
            "超出图片的部分被裁掉"
        )
        XCTAssertEqual(
            ImageAnnotationGeometry.pixelCropRect(normalized: CGRect(x: 2, y: 2, width: 1, height: 1), pixelSize: pixels),
            CGRect(origin: .zero, size: pixels),
            "完全越界时退回整图"
        )
    }

    func testRenderWithoutStrokesOrCropKeepsOriginalPixelSize() throws {
        let image = solidImage(size: CGSize(width: 300, height: 200), scale: 2)
        let rendered = ImageAnnotationGeometry.render(
            image: image,
            drawing: PKDrawing(),
            canvasSize: CGSize(width: 150, height: 100),
            normalizedCrop: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let cgImage = try XCTUnwrap(rendered.cgImage)
        XCTAssertEqual(cgImage.width, 600)
        XCTAssertEqual(cgImage.height, 400)
    }

    func testRenderAppliesCropInPixels() throws {
        let image = solidImage(size: CGSize(width: 300, height: 200), scale: 2)
        let rendered = ImageAnnotationGeometry.render(
            image: image,
            drawing: PKDrawing(),
            canvasSize: CGSize(width: 150, height: 100),
            normalizedCrop: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        )
        let cgImage = try XCTUnwrap(rendered.cgImage)
        XCTAssertEqual(cgImage.width, 300)
        XCTAssertEqual(cgImage.height, 200)
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ComposerClipboardImageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func solidImage(size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
