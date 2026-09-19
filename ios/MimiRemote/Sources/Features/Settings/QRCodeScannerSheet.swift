import AVFoundation
import SwiftUI
import UIKit

enum QRCodeScannerRecoveryAction: Equatable {
    case openSettings
    case retryScanning
    case manualConnection
}
enum QRCodeScannerFailure: Equatable {
    case permissionDenied
    case permissionRestricted
    case cameraUnavailable
    case configurationFailed(String)
    case rejectedCode(String)

    var message: String {
        switch self {
        case .permissionDenied:
            return L10n.text("ui.mimi_doesn_t_have_camera_permissions_and_can")
        case .permissionRestricted:
            return L10n.text("ui.the_current_device_restricts_camera_access_and_cannot")
        case .cameraUnavailable:
            return L10n.text("ui.the_current_device_does_not_have_a_camera")
        case .configurationFailed(let reason):
            return reason
        case .rejectedCode(let reason):
            return reason
        }
    }

    var recoveryActions: [QRCodeScannerRecoveryAction] {
        switch self {
        case .permissionDenied, .permissionRestricted:
            return [.openSettings, .manualConnection]
        case .cameraUnavailable, .configurationFailed:
            return [.manualConnection]
        case .rejectedCode:
            return [.retryScanning, .manualConnection]
        }
    }
}

enum QRCodeScannerSubmissionResult: Equatable {
    case accepted(String)
    case rejected(String)
}

struct QRCodeScannerSheet: View {
    @State private var scannerFailure: QRCodeScannerFailure?
    @State private var isCameraReady = false
    @State private var isSubmittingCode = false
    @State private var completionMessage: String?
    @State private var submissionTask: Task<Void, Never>?

    let onDismiss: () -> Void
    let onChooseManualConnection: () -> Void
    let onCode: (String) async -> QRCodeScannerSubmissionResult

    var body: some View {
        NavigationStack {
            ZStack {
                if let scannerFailure {
                    scannerFailureContent(scannerFailure)
                        .transition(.opacity)
                } else {
                    scannerContent
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(L10n.text("ui.scan_the_pairing_qr_code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("ui.close")) {
                        // 明确只改父页面持有的扫码展示状态，不能用嵌套环境 dismiss 误关设置页。
                        dismissScanner()
                    }
                    .accessibilityIdentifier("qrScanner.close")
                }
            }
        }
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
        }
    }

    private var isScanningEnabled: Bool {
        isCameraReady && !isSubmittingCode && completionMessage == nil && scannerFailure == nil
    }

    private var scannerContent: some View {
        ZStack {
            QRCodeScannerView(isScanningEnabled: isScanningEnabled) { value in
                submit(value)
            } onError: { failure in
                scannerFailure = failure
            } onReady: {
                isCameraReady = true
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
                .allowsHitTesting(false)

            if !isCameraReady {
                scannerStatusCard(
                    title: L10n.text("ui.starting_camera"),
                    message: L10n.text("ui.if_a_permission_request_pops_up_allow_camera"),
                    showsProgress: true
                )
            } else if let completionMessage {
                scannerStatusCard(
                    title: L10n.text("ui.connection_successful"),
                    message: completionMessage,
                    systemImage: "checkmark.circle.fill"
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityIdentifier("qrScanner.connectionSuccess")
            } else if isSubmittingCode {
                scannerStatusCard(
                    title: L10n.text("ui.qr_code_recognized"),
                    message: L10n.text("ui.verifying_mac_connection"),
                    showsProgress: true
                )
            }
        }
    }

    private func scannerStatusCard(
        title: String,
        message: String,
        systemImage: String? = nil,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
        .accessibilityElement(children: .combine)
    }

    private func scannerFailureContent(_ failure: QRCodeScannerFailure) -> some View {
        ZStack {
            Color.black

            VStack(spacing: 18) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(L10n.text("ui.unable_to_scan_code"))
                        .font(.title2.weight(.semibold))
                    Text(failure.message)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.76))
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    if failure.recoveryActions.contains(.openSettings) {
                        Button(L10n.text("ui.go_to_system_settings"), action: openAppSettings)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    if failure.recoveryActions.contains(.retryScanning) {
                        Button(L10n.text("ui.continue_to_scan_the_code")) {
                            isCameraReady = false
                            scannerFailure = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    if failure.recoveryActions.count == 1 {
                        Button(L10n.text("ui.use_manual_connection_instead"), action: chooseManualConnection)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        Button(L10n.text("ui.use_manual_connection_instead"), action: chooseManualConnection)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
                .frame(maxWidth: 320)
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(maxWidth: 440)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qrScanner.failure")
    }

    private func chooseManualConnection() {
        scannerFailure = nil
        // 父页面只负责展开已经存在的手动连接区域，扫码 Sheet 不复制连接表单和状态。
        onChooseManualConnection()
        dismissScanner()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            chooseManualConnection()
            return
        }
        scannerFailure = nil
        dismissScanner()
        UIApplication.shared.open(url)
    }

    private func dismissScanner(cancelSubmission: Bool = true) {
        if cancelSubmission {
            submissionTask?.cancel()
        }
        onDismiss()
    }

    private func submit(_ value: String) {
        guard !isSubmittingCode else {
            return
        }

        // 先停扫并在当前页面给出明确反馈；只有验证通过后才关闭，避免“相机刚弹出就退回”的错觉。
        isSubmittingCode = true
        scannerFailure = nil
        submissionTask?.cancel()
        submissionTask = Task { @MainActor in
            let result = await onCode(value)
            guard !Task.isCancelled else {
                return
            }

            switch result {
            case .accepted(let message):
                // 二维码可能在相机首帧就被识别；先展示明确完成态，避免直接关闭被误认为相机没有打开。
                isSubmittingCode = false
                completionMessage = message
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                dismissScanner(cancelSubmission: false)
            case .rejected(let message):
                isSubmittingCode = false
                scannerFailure = .rejectedCode(message)
            }
            submissionTask = nil
        }
    }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
    let isScanningEnabled: Bool
    let onCode: (String) -> Void
    let onError: (QRCodeScannerFailure) -> Void
    let onReady: () -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let viewController = QRCodeScannerViewController(onCode: onCode, onError: onError, onReady: onReady)
        viewController.setScanningEnabled(isScanningEnabled)
        return viewController
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {
        uiViewController.setScanningEnabled(isScanningEnabled)
    }
}

private final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "MimiRemote.QRCodeScanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didReadCode = false
    private var isScanningEnabled = false
    private var isViewVisible = false

    private let onCode: (String) -> Void
    private let onError: (QRCodeScannerFailure) -> Void
    private let onReady: () -> Void

    init(
        onCode: @escaping (String) -> Void,
        onError: @escaping (QRCodeScannerFailure) -> Void,
        onReady: @escaping () -> Void
    ) {
        self.onCode = onCode
        self.onError = onError
        self.onReady = onReady
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isViewVisible = true
        if isScanningEnabled, previewLayer != nil {
            startScanning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewVisible = false
        stopScanning()
    }

    deinit {
        stopScanning()
    }

    func setScanningEnabled(_ enabled: Bool) {
        guard isScanningEnabled != enabled else {
            return
        }
        isScanningEnabled = enabled
        if enabled {
            didReadCode = false
            if isViewVisible, previewLayer != nil {
                startScanning()
            }
        } else {
            stopScanning()
        }
    }

    private func prepareCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.reportFailure(.permissionDenied)
                    }
                }
            }
        case .denied:
            reportFailure(.permissionDenied)
        case .restricted:
            reportFailure(.permissionRestricted)
        @unknown default:
            reportFailure(.cameraUnavailable)
        }
    }

    private func configureSession() {
        guard previewLayer == nil else {
            startScanning()
            return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            reportFailure(.cameraUnavailable)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                reportFailure(.configurationFailed(L10n.text("ui.unable_to_access_camera_input_please_use_manual")))
                return
            }
            captureSession.addInput(input)
        } catch {
            reportFailure(.configurationFailed(L10n.format("ui.failed_to_open_camera_value", error.localizedDescription)))
            return
        }

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            reportFailure(.configurationFailed(L10n.text("ui.the_current_camera_does_not_support_qr_code")))
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        reportReady()

        if isScanningEnabled, isViewVisible {
            startScanning()
        }
    }

    private func reportFailure(_ failure: QRCodeScannerFailure) {
        // Representable 创建和系统权限回调期间不能同步改写 SwiftUI State，统一延后到下一次主队列。
        DispatchQueue.main.async { [weak self] in
            self?.onError(failure)
        }
    }

    private func reportReady() {
        // 相机配置也可能发生在 makeUIViewController 链路内，同样异步交回 SwiftUI。
        DispatchQueue.main.async { [weak self] in
            self?.onReady()
        }
    }

    private func startScanning() {
        // AVCaptureSession 启停放到后台队列，避免设置页打开扫码时阻塞 SwiftUI 主线程。
        sessionQueue.async { [captureSession] in
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    private func stopScanning() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReadCode,
              let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr }),
              let value = object.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return
        }

        // 第一次读到二维码后立刻停扫，防止同一个码连续触发多次连接测试。
        didReadCode = true
        stopScanning()
        onCode(value)
    }
}
