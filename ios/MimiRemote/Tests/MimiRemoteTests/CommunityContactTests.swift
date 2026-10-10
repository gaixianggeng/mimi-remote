import CoreImage
import XCTest
@testable import MimiRemote

final class CommunityContactTests: XCTestCase {
    func testMissingQRCodePayloadHidesEntry() {
        XCTAssertNil(CommunityContact.make(qrCodePayload: "", weChatID: "mimi"))
        XCTAssertNil(CommunityContact.make(qrCodePayload: "  \n", weChatID: "mimi"))
    }

    func testValuesAreTrimmedAndEmptyWeChatIDIsDropped() {
        let contact = CommunityContact.make(qrCodePayload: " https://u.wechat.com/example \n", weChatID: "  ")
        XCTAssertEqual(contact?.qrCodePayload, "https://u.wechat.com/example")
        XCTAssertNil(contact?.weChatID)

        let withID = CommunityContact.make(qrCodePayload: "https://u.wechat.com/example", weChatID: " mimi_remote ")
        XCTAssertEqual(withID?.weChatID, "mimi_remote")
    }

    func testBundledContactProducesScannableQRCode() throws {
        guard let contact = CommunityContact.bundled else {
            throw XCTSkip("No bundled community contact configured")
        }
        XCTAssertEqual(try decodedPayload(CommunityQRCode.image(for: contact.qrCodePayload)), contact.qrCodePayload)
    }

    func testGeneratedQRCodeDecodesToPayloadWithQuietZone() throws {
        let payload = "https://u.wechat.com/EXAMPLE-community-entry?s=2"
        let pixelsPerModule: CGFloat = 8
        let image = try XCTUnwrap(CommunityQRCode.image(for: payload, pixelsPerModule: pixelsPerModule))

        XCTAssertEqual(try decodedPayload(image), payload)
        XCTAssertEqual(image.size.width, image.size.height)
        XCTAssertEqual(image.size.width.truncatingRemainder(dividingBy: pixelsPerModule), 0)

        // 白边画进图片本身：深色卡片上和保存到相册后都能直接扫。
        let quietZone = Int(pixelsPerModule * CommunityQRCode.quietZoneModules)
        let cgImage = try XCTUnwrap(image.cgImage)
        for point in [(0, 0), (quietZone - 1, quietZone - 1), (cgImage.width - 1, cgImage.height - 1)] {
            XCTAssertTrue(isWhite(cgImage, x: point.0, y: point.1), "Expected quiet zone at \(point)")
        }
    }

    func testEmptyPayloadProducesNoImage() {
        XCTAssertNil(CommunityQRCode.image(for: ""))
    }

    private func decodedPayload(_ image: UIImage?) throws -> String? {
        let cgImage = try XCTUnwrap(image?.cgImage)
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let features = detector.features(in: CIImage(cgImage: cgImage))
        return (features.first as? CIQRCodeFeature)?.messageString
    }

    private func isWhite(_ image: CGImage, x: Int, y: Int) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240
    }
}
