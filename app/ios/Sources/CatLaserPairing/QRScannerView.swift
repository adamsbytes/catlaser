#if canImport(AVFoundation) && canImport(UIKit) && canImport(SwiftUI) && os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI wrapper around `AVCaptureSession` with a single-purpose
/// `.qr` metadata detector.
///
/// The host composes this inside `PairingView` and passes a
/// `didDecode` closure. Every scanned QR payload flows through
/// `QRPayloadDecision.evaluate`, and only `.accepted(code)` callbacks
/// fire — `.ignored` and `.rejected` are swallowed, logged at the
/// scanner level (the UI has a banner space for an invalid-pairing
/// warning but intentionally does NOT treat every non-pairing QR as
/// an error, since a real camera sees many irrelevant codes).
///
/// Camera permission: this view assumes the caller has already
/// checked `CameraPermissionGate.requestAccess()` and observed an
/// `.authorized` status before presenting. If the view is shown with
/// camera access denied, the capture session simply does not start;
/// the `PairingView` shows an explicit denial-screen fallback so the
/// user is never left staring at a black rectangle wondering why
/// nothing is happening.
///
/// Thread model:
///
/// * `AVCaptureSession` operates on a private dedicated queue. The
///   metadata callback fires on the scanner's delegate queue, and
///   the representable re-enters the `@MainActor` before calling
///   `didDecode` so the view model can mutate its state safely.
/// * `startRunning()` is explicitly dispatched to a background
///   queue; Apple's docs warn that calling it on main is a UI hitch.
/// * `stopRunning()` on view disappear is synchronous — fast because
///   we scheduled nothing expensive on the session queue.
public struct QRScannerView: UIViewControllerRepresentable {
    public let onDecode: @MainActor (PairingCode) -> Void
    public let onRejected: @MainActor (PairingCodeError) -> Void

    public init(
        onDecode: @escaping @MainActor (PairingCode) -> Void,
        onRejected: @escaping @MainActor (PairingCodeError) -> Void,
    ) {
        self.onDecode = onDecode
        self.onRejected = onRejected
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onDecode: onDecode, onRejected: onRejected)
    }

    public func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        // Nothing to update — the view controller owns the entire
        // capture session lifecycle and has no state that derives
        // from SwiftUI bindings. Every knob (restart, stop) flows
        // through the representable being added/removed from the
        // view tree.
    }

    public final class Coordinator: QRScannerViewControllerDelegate {
        private let onDecode: @MainActor (PairingCode) -> Void
        private let onRejected: @MainActor (PairingCodeError) -> Void

        init(
            onDecode: @escaping @MainActor (PairingCode) -> Void,
            onRejected: @escaping @MainActor (PairingCodeError) -> Void,
        ) {
            self.onDecode = onDecode
            self.onRejected = onRejected
        }

        func scannerDidDecode(payload: String) {
            let decision = QRPayloadDecision.evaluate(payload)
            switch decision {
            case let .accepted(code):
                Task { @MainActor in
                    self.onDecode(code)
                }
            case let .rejected(error):
                Task { @MainActor in
                    self.onRejected(error)
                }
            case .ignored:
                break
            }
        }
    }
}

protocol QRScannerViewControllerDelegate: AnyObject {
    func scannerDidDecode(payload: String)
}

/// UIKit view controller that owns the `AVCaptureSession`.
///
/// Lifecycle:
///
/// * `viewDidLoad`: configure the session (video input + metadata
///   output looking for `.qr`), wire a preview layer that tracks
///   the view's bounds.
/// * `viewDidAppear`: start the session on the background queue.
/// * `viewWillDisappear`: stop the session. Idempotent.
///
/// We deliberately do NOT start the session from `viewDidLoad` —
/// SwiftUI may instantiate the view controller eagerly and then
/// dismiss it before it ever reaches `.appear`. Starting only on
/// appear keeps the camera dark until the user actually sees the
/// scanner.
public final class QRScannerViewController: UIViewController {
    weak var delegate: QRScannerViewControllerDelegate?

    private let sessionQueue = DispatchQueue(label: "catlaser.pairing.qr-scanner.session", qos: .userInitiated)
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let metadataDelegateQueue = DispatchQueue(label: "catlaser.pairing.qr-scanner.metadata", qos: .userInitiated)

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            // No camera present (e.g. simulator without a camera
            // passthrough). The scanner will stay black; the host
            // `PairingView` falls back to manual entry.
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            // Camera input could not be opened (permission denied,
            // device busy). Fall through; the UI already has a
            // permission-denial screen if that's the cause.
            return
        }
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: metadataDelegateQueue)
        // ObjectTypes can only be set AFTER the output is added to
        // a session — Apple's docs; early assignment silently
        // no-ops.
        metadataOutput.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
        self.captureSession = session
    }

    private func startSession() {
        guard let session = captureSession, !session.isRunning else { return }
        sessionQueue.async {
            session.startRunning()
        }
    }

    private func stopSession() {
        guard let session = captureSession, session.isRunning else { return }
        sessionQueue.async {
            session.stopRunning()
        }
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    public func metadataOutput(
        _: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from _: AVCaptureConnection,
    ) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  let payload = readable.stringValue
            else { continue }
            delegate?.scannerDidDecode(payload: payload)
        }
    }
}
#endif
