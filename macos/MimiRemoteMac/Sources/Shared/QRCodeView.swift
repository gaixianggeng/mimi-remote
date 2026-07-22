import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let value: String
    var size: CGFloat = 280

    var body: some View {
        if let image = QRCodeGenerator.image(for: value) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("Mimi Remote 配对二维码")
        } else {
            ContentUnavailableView("二维码生成失败", systemImage: "qrcode")
                .frame(width: size, height: size)
        }
    }
}

enum QRCodeGenerator {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = context.createCGImage(output, from: output.extent)
        else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
