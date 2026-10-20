import PencilKit
import SwiftUI
import UIKit

/// 发送前标注图片附件（#829）：PencilKit 画笔（Pencil 与手指都可画，系统工具板提供笔、荧光笔、
/// 橡皮、尺子）加上四角可拖动的裁剪框。完成时把原图、笔迹合成后再按裁剪框裁切，取消不改原图。
struct ImageAnnotationEditor: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let image: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var canvasView = PKCanvasView()
    @State private var canvasSize: CGSize = .zero
    @State private var isCropping = false
    /// 以图片宽高为 1 的归一化裁剪框。
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            GeometryReader { proxy in
                let fitted = ImageAnnotationGeometry.fittedSize(image.size, in: proxy.size, padding: 16)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                    AnnotationCanvas(canvasView: canvasView, isDrawingEnabled: !isCropping)
                        .frame(width: fitted.width, height: fitted.height)
                    if isCropping {
                        ImageCropOverlay(rect: $cropRect, size: fitted, tint: tokens.accent)
                            .frame(width: fitted.width, height: fitted.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear { canvasSize = fitted }
                .onChange(of: fitted) { _, size in canvasSize = size }
            }
            .background(Color.black.opacity(colorScheme == .dark ? 1 : 0.92))
            .navigationTitle(L10n.text("ui.annotate_image"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.done")) { onDone(renderedImage()) }
                        .accessibilityIdentifier("annotation.done")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        canvasView.undoManager?.undo()
                    } label: {
                        Label(L10n.text("ui.undo"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(isCropping)
                    Spacer()
                    Button {
                        isCropping.toggle()
                    } label: {
                        Label(L10n.text("ui.crop_image"), systemImage: "crop")
                    }
                    .tint(isCropping ? tokens.accent : nil)
                    .accessibilityIdentifier("annotation.crop")
                    if cropRect != CGRect(x: 0, y: 0, width: 1, height: 1) {
                        Button(L10n.text("ui.reset_crop")) {
                            cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                        }
                    }
                }
            }
        }
    }

    private func renderedImage() -> UIImage {
        ImageAnnotationGeometry.render(
            image: image,
            drawing: canvasView.drawing,
            canvasSize: canvasSize,
            normalizedCrop: cropRect
        )
    }
}

enum ImageAnnotationGeometry {
    /// 等比缩放到可用区域内（四周留白），与 `Image.scaledToFit` 一致。
    static func fittedSize(_ imageSize: CGSize, in container: CGSize, padding: CGFloat) -> CGSize {
        let available = CGSize(
            width: max(1, container.width - padding * 2),
            height: max(1, container.height - padding * 2)
        )
        guard imageSize.width > 0, imageSize.height > 0 else { return available }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        return CGSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
    }

    /// 归一化裁剪框换算成像素矩形，并收在图片范围内。
    static func pixelCropRect(normalized: CGRect, pixelSize: CGSize) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clamped = normalized.intersection(unit)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            return CGRect(origin: .zero, size: pixelSize)
        }
        // 先把四条边各自对齐到像素再相减，避免 0.7 - 0.2 这类浮点误差少算一像素。
        let minX = (clamped.minX * pixelSize.width).rounded()
        let minY = (clamped.minY * pixelSize.height).rounded()
        let maxX = (clamped.maxX * pixelSize.width).rounded()
        let maxY = (clamped.maxY * pixelSize.height).rounded()
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    static func render(image: UIImage, drawing: PKDrawing, canvasSize: CGSize, normalizedCrop: CGRect) -> UIImage {
        let imageSize = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let composed = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: imageSize))
            guard canvasSize.width > 0, canvasSize.height > 0, !drawing.strokes.isEmpty else { return }
            let strokeScale = image.scale * imageSize.width / canvasSize.width
            let strokes = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: strokeScale)
            strokes.draw(in: CGRect(origin: .zero, size: imageSize))
        }
        guard let cgImage = composed.cgImage else { return composed }
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let crop = pixelCropRect(normalized: normalizedCrop, pixelSize: pixelSize)
        guard crop.size != pixelSize, let cropped = cgImage.cropping(to: crop) else { return composed }
        return UIImage(cgImage: cropped, scale: composed.scale, orientation: .up)
    }
}

private struct AnnotationCanvas: UIViewRepresentable {
    let canvasView: PKCanvasView
    let isDrawingEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .systemRed, width: 6)
        context.coordinator.toolPicker.addObserver(canvasView)
        DispatchQueue.main.async {
            context.coordinator.toolPicker.setVisible(true, forFirstResponder: canvasView)
            canvasView.becomeFirstResponder()
        }
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.isUserInteractionEnabled = isDrawingEnabled
        context.coordinator.toolPicker.setVisible(isDrawingEnabled, forFirstResponder: uiView)
    }

    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: uiView)
        coordinator.toolPicker.removeObserver(uiView)
    }

    final class Coordinator {
        let toolPicker = PKToolPicker()
    }
}

/// 裁剪框：框外压暗，四角拖动调整，最小保留 10%。
private struct ImageCropOverlay: View {
    @Binding var rect: CGRect
    let size: CGSize
    let tint: Color

    private static let minimumFraction: CGFloat = 0.1

    var body: some View {
        let frame = CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            Rectangle()
                .stroke(tint, lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            ForEach(Corner.allCases, id: \.self) { corner in
                handle(for: corner, frame: frame)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("ui.crop_image"))
    }

    private enum Corner: CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private func handle(for corner: Corner, frame: CGRect) -> some View {
        let point: CGPoint
        switch corner {
        case .topLeading: point = CGPoint(x: frame.minX, y: frame.minY)
        case .topTrailing: point = CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeading: point = CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomTrailing: point = CGPoint(x: frame.maxX, y: frame.maxY)
        }
        return Circle()
            .fill(tint)
            .frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        move(corner, to: value.location)
                    }
            )
    }

    private func move(_ corner: Corner, to location: CGPoint) {
        guard size.width > 0, size.height > 0 else { return }
        let x = min(max(location.x / size.width, 0), 1)
        let y = min(max(location.y / size.height, 0), 1)
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let gap = Self.minimumFraction
        switch corner {
        case .topLeading:
            minX = min(x, maxX - gap); minY = min(y, maxY - gap)
        case .topTrailing:
            maxX = max(x, minX + gap); minY = min(y, maxY - gap)
        case .bottomLeading:
            minX = min(x, maxX - gap); maxY = max(y, minY + gap)
        case .bottomTrailing:
            maxX = max(x, minX + gap); maxY = max(y, minY + gap)
        }
        rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
