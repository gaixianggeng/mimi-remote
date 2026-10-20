import PencilKit
import XCTest
@testable import MimiRemote

final class ComposerClipboardImageTests: XCTestCase {
    // MARK: - 剪贴板提示

    func testNoticeAppearsOnlyForImagesThatWereNotDismissed() {
        var state = ComposerClipboardImageState()
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
        var state = ComposerClipboardImageState()
        state.refresh(hasImages: false, changeCount: 3, acceptsImages: true)
        XCTAssertFalse(state.isVisible, "只有文字时不出现")
        state.refresh(hasImages: true, changeCount: 4, acceptsImages: false)
        XCTAssertFalse(state.isVisible, "不收附件的通道（DeepSeek）不出现")
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
