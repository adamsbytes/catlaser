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
/// ## Reticle
///
/// The scanner constrains metadata detection to the centre 70% × 70%
/// of the frame so a QR sitting in the middle of the camera's view
/// (where the reticle overlay tells the user to put it) is what the
/// detector matches against. The host overlays a corresponding
/// reticle frame on top of the preview; the two share the same
/// fractional rect.
///
/// ## Torch
///
/// The view controller exposes a ``setTorchEnabled(_:)`` method so the
/// host can wire a flashlight toggle; ``isTorchAvailable`` reports
/// whether the device's capture device has a torch (front cameras and
/// older simulators do not). Errors locking / unlocking the device
/// for configuration are silently absorbed — the worst case is the
/// torch button does nothing — because every recoverable failure mode
/// here is also a no-op (camera in use elsewhere, hardware fault).
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
    /// Bound torch-on flag. Two-way: the wrapper writes back ``false``
    /// if the underlying device has no torch (so the host's button
    /// can disable itself) or if a configuration lock failed.
    @Binding public var torchOn: Bool
    /// Reports whether the active capture device supports a torch.
    /// Two-way: the host reads to gate the torch button; the wrapper
    /// writes once on first configure.
    @Binding public var torchAvailable: Bool

    public init(
        torchOn: Binding<Bool>,
        torchAvailable: Binding<Bool>,
        onDecode: @escaping @MainActor (PairingCode) -> Void,
        onRejected: @escaping @MainActor (PairingCodeError) -> Void,
    ) {
        self._torchOn = torchOn
        self._torchAvailable = torchAvailable
        self.onDecode = onDecode
        self.onRejected = onRejected
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onDecode: onDecode,
            onRejected: onRejected,
            torchOnBinding: $torchOn,
            torchAvailableBinding: $torchAvailable,
        )
    }

    public func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        // Push the desired torch state into the view controller. The
        // controller drops the call if the device has no torch or if
        // the requested state already matches — no flicker on each
        // SwiftUI update tick.
        uiViewController.setTorchEnabled(torchOn)
    }

    public final class Coordinator: QRScannerViewControllerDelegate {
        private let onDecode: @MainActor (PairingCode) -> Void
        private let onRejected: @MainActor (PairingCodeError) -> Void
        private let torchOnBinding: Binding<Bool>
        private let torchAvailableBinding: Binding<Bool>

        init(
            onDecode: @escaping @MainActor (PairingCode) -> Void,
            onRejected: @escaping @MainActor (PairingCodeError) -> Void,
            torchOnBinding: Binding<Bool>,
            torchAvailableBinding: Binding<Bool>,
        ) {
            self.onDecode = onDecode
            self.onRejected = onRejected
            self.torchOnBinding = torchOnBinding
            self.torchAvailableBinding = torchAvailableBinding
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

        func scannerDidConfigureTorch(available: Bool) {
            // Push the hardware capability back to the SwiftUI state
            // so the host can hide / disable its torch button when no
            // torch exists. Main-actor hop because Binding writes are
            // documented main-actor (SwiftUI consumes on main).
            Task { @MainActor in
                self.torchAvailableBinding.wrappedValue = available
                if !available {
                    self.torchOnBinding.wrappedValue = false
                }
            }
        }

        func scannerTorchDidFailToActivate() {
            // The hardware refused (busy, locked by another app). Snap
            // the binding back to off so the toggle visually reflects
            // ground truth — the torch is NOT on, the toggle should
            // not pretend otherwise.
            Task { @MainActor in
                self.torchOnBinding.wrappedValue = false
            }
        }
    }
}

protocol QRScannerViewControllerDelegate: AnyObject {
    func scannerDidDecode(payload: String)
    func scannerDidConfigureTorch(available: Bool)
    func scannerTorchDidFailToActivate()
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
    private var captureDevice: AVCaptureDevice?
    private var metadataOutput: AVCaptureMetadataOutput?
    private let metadataDelegateQueue = DispatchQueue(label: "catlaser.pairing.qr-scanner.metadata", qos: .userInitiated)

    /// Fractional bounds of the on-screen reticle (centred 70% × 70%).
    /// The scanner constrains metadata detection to this area so a QR
    /// the user has positioned inside the visible frame is the one
    /// the detector matches against; QRs sitting outside the frame
    /// are ignored, which improves the UX of pairing in a cluttered
    /// scene (other QR codes on the table, packaging, etc.). The host
    /// overlay uses the same constants to draw the visible frame.
    public static let reticleFractionalRect = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        // ``rectOfInterest`` is in image-coordinate space (0…1 within
        // the camera's output), and the conversion from preview-
        // coordinates is preview-layer-aware (handles videoGravity,
        // orientation). Recomputed on layout because the preview
        // layer's frame just changed and the cached value is stale.
        if let preview = previewLayer, let metadataOutput {
            let previewRect = previewRect(for: Self.reticleFractionalRect, in: preview.bounds)
            metadataOutput.rectOfInterest = preview.metadataOutputRectConverted(fromLayerRect: previewRect)
        }
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Make sure the torch isn't left burning when the scanner
        // goes off-screen. Lock-and-unlock the device to clear any
        // active torch state; failure is benign (device busy, etc.).
        setTorchEnabled(false)
        stopSession()
    }

    /// Push the desired torch state to the capture device. No-op when
    /// the device has no torch, when it is not currently authorised,
    /// or when the requested state already matches the current
    /// reading. Failures are reported to the delegate so the host's
    /// toggle can revert.
    public func setTorchEnabled(_ enabled: Bool) {
        guard let device = captureDevice, device.hasTorch, device.isTorchAvailable else {
            return
        }
        let desiredMode: AVCaptureDevice.TorchMode = enabled ? .on : .off
        if device.torchMode == desiredMode { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = desiredMode
        } catch {
            delegate?.scannerTorchDidFailToActivate()
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            // No camera present (e.g. simulator without a camera
            // passthrough). The scanner will stay black; the host
            // `PairingView` falls back to manual entry.
            delegate?.scannerDidConfigureTorch(available: false)
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
            delegate?.scannerDidConfigureTorch(available: false)
            return
        }
        guard session.canAddInput(input) else {
            delegate?.scannerDidConfigureTorch(available: false)
            return
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            delegate?.scannerDidConfigureTorch(available: false)
            return
        }
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
        self.captureDevice = device
        self.metadataOutput = metadataOutput

        // Report torch availability up to the SwiftUI state. The
        // capability check survives this side of the configuration
        // path even if the session never starts (e.g. permission was
        // denied between authorising and view-appear) — the host
        // handles that case via its permission gate.
        delegate?.scannerDidConfigureTorch(available: device.hasTorch)
    }

    /// Convert a fractional (0…1) sub-rect into preview-layer
    /// coordinates. ``AVCaptureVideoPreviewLayer/metadataOutputRectConverted``
    /// expects layer-space input and returns image-space output, so
    /// we have to take the round-trip through layer space rather than
    /// applying the fractional rect directly.
    private func previewRect(for fractional: CGRect, in layerBounds: CGRect) -> CGRect {
        CGRect(
            x: layerBounds.origin.x + fractional.origin.x * layerBounds.width,
            y: layerBounds.origin.y + fractional.origin.y * layerBounds.height,
            width: fractional.width * layerBounds.width,
            height: fractional.height * layerBounds.height,
        )
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
