import PencilKit
import XCTest
@testable import MimiRemote

@MainActor
final class ComposerClipboardImageTests: XCTestCase {
    // MARK: - 剪贴板提示

    func testNoticeAppearsOnlyForImagesThatWereNotDismissed() {
        var state = ComposerClipboardImageState(dismissStore: ComposerClipboardImageDismissStore())
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
        var state = ComposerClipboardImageState(dismissStore: ComposerClipboardImageDismissStore())
        state.refresh(hasImages: false, changeCount: 3, acceptsImages: true)
        XCTAssertFalse(state.isVisible, "只有文字时不出现")
        state.refresh(hasImages: true, changeCount: 4, acceptsImages: false)
        XCTAssertFalse(state.isVisible, "不收附件的通道（DeepSeek）不出现")
    }

    func testDismissPersistsAcrossStateRecreationUntilClipboardChanges() {
        let sharedStore = ComposerClipboardImageDismissStore()

        var initialState = ComposerClipboardImageState(dismissStore: sharedStore)
        initialState.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        XCTAssertTrue(initialState.isVisible)

        initialState.dismiss(changeCount: 7)
        XCTAssertFalse(initialState.isVisible)

        // 模拟离开会话再重新进入，重建 ComposerView 及其 @State（仍共享同一进程内 store）。
        var recreatedState = ComposerClipboardImageState(dismissStore: sharedStore)
        recreatedState.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        XCTAssertFalse(recreatedState.isVisible, "重新进入会话后，同一 changeCount 的剪贴板图片不再重复提示")

        recreatedState.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertTrue(recreatedState.isVisible, "剪贴板内容更新为新 changeCount 后再次显示")
    }

    func testDismissResetsAfterProcessOrDeviceRestartWithMatchingChangeCount() {
        let storeBeforeRestart = ComposerClipboardImageDismissStore()
        var stateBeforeRestart = ComposerClipboardImageState(dismissStore: storeBeforeRestart)
        stateBeforeRestart.refresh(hasImages: true, changeCount: 1, acceptsImages: true)
        stateBeforeRestart.dismiss(changeCount: 1)
        XCTAssertFalse(stateBeforeRestart.isVisible)

        // 模拟设备重启 / 新进程：使用全新应用级共享存储，changeCount 重新从 0/1 开始不再撞号。
        let storeAfterRestart = ComposerClipboardImageDismissStore()
        var stateAfterRestart = ComposerClipboardImageState(dismissStore: storeAfterRestart)
        stateAfterRestart.refresh(hasImages: true, changeCount: 1, acceptsImages: true)
        XCTAssertTrue(stateAfterRestart.isVisible, "重启/新进程后相同 changeCount 的新图片应再次提示")
    }

    func testDismissPersistsZeroChangeCountAndSurvivesRedundantDismiss() {
        let sharedStore = ComposerClipboardImageDismissStore()

        var initialState = ComposerClipboardImageState(dismissStore: sharedStore)
        initialState.refresh(hasImages: true, changeCount: 0, acceptsImages: true)
        XCTAssertTrue(initialState.isVisible)

        initialState.dismissCurrent()
        // 已经关闭后再调一次无参 dismiss，不应抹掉刚记录的 changeCount。
        initialState.dismissCurrent()

        var recreatedState = ComposerClipboardImageState(dismissStore: sharedStore)
        recreatedState.refresh(hasImages: true, changeCount: 0, acceptsImages: true)
        XCTAssertFalse(recreatedState.isVisible, "changeCount 为 0 时也应正确区分未记录与已关闭")

        recreatedState.refresh(hasImages: true, changeCount: 1, acceptsImages: true)
        XCTAssertTrue(recreatedState.isVisible)
    }

    func testDismissWithoutVisibleBannerSuppressesPeerAndRecreatedState() {
        let sharedStore = ComposerClipboardImageDismissStore()

        var stateA = ComposerClipboardImageState(dismissStore: sharedStore)
        var stateB = ComposerClipboardImageState(dismissStore: sharedStore)
        XCTAssertNil(stateA.availableChangeCount)

        // 保留 availableChangeCount == nil 的路径：未显示横幅时通过 ⌘V 粘贴直接记录当前 changeCount。
        stateA.dismiss(changeCount: 12)

        stateB.refresh(hasImages: true, changeCount: 12, acceptsImages: true)
        XCTAssertFalse(stateB.isVisible, "共享存储中的已有实例刷新时也应感知已关闭状态")

        var recreatedState = ComposerClipboardImageState(dismissStore: sharedStore)
        recreatedState.refresh(hasImages: true, changeCount: 12, acceptsImages: true)
        XCTAssertFalse(recreatedState.isVisible)
        recreatedState.refresh(hasImages: true, changeCount: 13, acceptsImages: true)
        XCTAssertTrue(recreatedState.isVisible)
    }

    func testConcurrentStatesSyncDismissImmediatelyWithoutWaitingForPeerRefresh() {
        let sharedStore = ComposerClipboardImageDismissStore()
        var stateA = ComposerClipboardImageState(dismissStore: sharedStore)
        var stateB = ComposerClipboardImageState(dismissStore: sharedStore)

        stateA.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        stateB.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        XCTAssertTrue(stateA.isVisible)
        XCTAssertTrue(stateB.isVisible)

        stateA.dismiss(changeCount: 7)
        XCTAssertFalse(stateA.isVisible)
        XCTAssertFalse(stateB.isVisible, "并存实例无需等待手动刷新即可同步收起旧横幅")

        stateB.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertTrue(stateB.isVisible)
    }

    func testExplicitPasteChangeCountRecordsNewerCountEvenWhenBannerCachedOlderCount() {
        let sharedStore = ComposerClipboardImageDismissStore()
        var state = ComposerClipboardImageState(dismissStore: sharedStore)

        // 横幅仍缓存 7，但键盘实际粘贴了计数 8 的图片。
        state.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        XCTAssertEqual(state.visibleChangeCount, 7)

        state.dismiss(changeCount: 8)
        XCTAssertEqual(state.dismissedChangeCount, 8)
        XCTAssertFalse(state.isVisible, "粘贴更新的计数后旧横幅同步收起")

        state.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertFalse(state.isVisible, "已粘贴的 8 不应再次弹出")

        state.refresh(hasImages: true, changeCount: 9, acceptsImages: true)
        XCTAssertTrue(state.isVisible, "新图片 9 仍会正常提示")
    }

    func testStaleBannerPasteAndStaleDismissDoNotHideNewerDisplayedContent() {
        let sharedStore = ComposerClipboardImageDismissStore()
        var state = ComposerClipboardImageState(dismissStore: sharedStore)

        state.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        // 在旧 provider 到达前，界面已经刷新到 8。
        state.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertEqual(state.visibleChangeCount, 8)

        let confirmed = state.dismissForBannerPaste(
            displayedChangeCount: 7,
            currentPasteboardChangeCount: 8
        )
        XCTAssertFalse(confirmed, "旧 provider 到达时已显示 8，不应确认关闭")
        XCTAssertNil(state.dismissedChangeCount)
        XCTAssertEqual(state.visibleChangeCount, 8)
        XCTAssertTrue(state.isVisible, "不应把 7 的旧回调覆盖成隐藏 8")

        // 即使旧横幅 7 的关闭按钮事件滞后到达，也不得隐藏当前正在显示的 8。
        state.dismiss(changeCount: 7)
        XCTAssertEqual(state.dismissedChangeCount, 7)
        XCTAssertEqual(state.visibleChangeCount, 8)
        XCTAssertTrue(state.isVisible)

        state.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertTrue(state.isVisible)

        // 8 被关闭后，再到达过期的 7 关闭事件不得把记录回退覆盖为 7。
        state.dismiss(changeCount: 8)
        XCTAssertEqual(state.dismissedChangeCount, 8)
        XCTAssertFalse(state.isVisible)

        state.dismiss(changeCount: 7)
        XCTAssertEqual(state.dismissedChangeCount, 8)
        state.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertFalse(state.isVisible, "过期关闭事件不得覆盖更新的关闭记录")
    }

    func testBannerPasteConfirmSucceedsWhenMatchingAndPreservesPromptWhenAmbiguous() {
        let sharedStore = ComposerClipboardImageDismissStore()
        var state = ComposerClipboardImageState(dismissStore: sharedStore)

        // 横幅仍显示 7，但 PasteButton 回调瞬间剪贴板已变成 8：存在歧义，保留新内容提示。
        state.refresh(hasImages: true, changeCount: 7, acceptsImages: true)
        let ambiguous = state.dismissForBannerPaste(
            displayedChangeCount: 7,
            currentPasteboardChangeCount: 8
        )
        XCTAssertFalse(ambiguous)
        XCTAssertNil(state.dismissedChangeCount)

        state.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertEqual(state.visibleChangeCount, 8)

        // 计数完全一致时同步确认并关闭。
        let confirmed = state.dismissForBannerPaste(
            displayedChangeCount: 8,
            currentPasteboardChangeCount: 8
        )
        XCTAssertTrue(confirmed)
        XCTAssertEqual(state.dismissedChangeCount, 8)
        XCTAssertFalse(state.isVisible)

        var recreatedState = ComposerClipboardImageState(dismissStore: sharedStore)
        recreatedState.refresh(hasImages: true, changeCount: 8, acceptsImages: true)
        XCTAssertFalse(recreatedState.isVisible)
    }

    func testCommandSubmitTextViewPasteCapturesChangeCountAtReadTime() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        pasteboard.image = solidImage(size: CGSize(width: 24, height: 24), scale: 1)
        let staleCount = pasteboard.changeCount

        let sharedStore = ComposerClipboardImageDismissStore()
        var state = ComposerClipboardImageState(dismissStore: sharedStore)
        state.refresh(hasImages: true, changeCount: staleCount, acceptsImages: true)
        XCTAssertEqual(state.visibleChangeCount, staleCount)

        // 剪贴板写入新图片后横幅尚未刷新（仍缓存旧计数），直接触发键盘粘贴。
        pasteboard.image = solidImage(size: CGSize(width: 32, height: 32), scale: 1)
        let pastedCount = pasteboard.changeCount
        XCTAssertGreaterThan(pastedCount, staleCount)

        let textView = CommandSubmitTextView()
        textView.pasteboardProvider = { pasteboard }
        var capturedImageCount = 0
        var capturedChangeCount: Int?
        textView.onPasteImages = { images, changeCount in
            capturedImageCount = images.count
            capturedChangeCount = changeCount
            state.dismiss(changeCount: changeCount)
        }

        textView.paste(nil)

        XCTAssertEqual(capturedImageCount, 1)
        XCTAssertEqual(capturedChangeCount, pastedCount)
        XCTAssertEqual(state.dismissedChangeCount, pastedCount)
        XCTAssertFalse(state.isVisible)

        state.refresh(hasImages: true, changeCount: pastedCount, acceptsImages: true)
        XCTAssertFalse(state.isVisible, "键盘粘贴捕获读取瞬间的 changeCount 后，不应再提示同一图片")
    }

    func testPreparingCountIsScopedAndBalanced() {
        var state = ComposerClipboardImageState(dismissStore: ComposerClipboardImageDismissStore())
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

    private func solidImage(size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
