#if canImport(SwiftUI)
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// SwiftUI pairing screen. Thin shell over `PairingViewModel` —
/// every action binds to a VM method; the view holds no local
/// state of its own. Tests exercise the VM directly.
public struct PairingView: View {
    @Bindable private var viewModel: PairingViewModel

    public init(viewModel: PairingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            contentView
        }
        .animation(.easeInOut(duration: 0.2), value: phaseTag)
        .task {
            await viewModel.start()
        }
    }

    private var phaseTag: String {
        switch viewModel.phase {
        case .checkingExisting: "checkingExisting"
        case let .needsCameraPermission(status): "needsCameraPermission:\(status)"
        case .scanning: "scanning"
        case .manualEntry: "manualEntry"
        case .exchanging: "exchanging"
        case .paired: "paired"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.phase {
        case .checkingExisting:
            busyView(label: nil)
        case let .needsCameraPermission(status):
            permissionView(status: status)
        case .scanning:
            scanningView
        case let .manualEntry(draft):
            manualEntryView(draft: draft)
        case .exchanging:
            busyView(label: PairingStrings.exchangingLabel)
        case let .paired(device):
            pairedView(device: device)
        case let .failed(error):
            failedView(error: error)
        }
    }

    private func busyView(label: String?) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.white)
            if let label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var scanningView: some View {
        ZStack(alignment: .bottom) {
            #if canImport(AVFoundation) && canImport(UIKit) && os(iOS)
            QRScannerView(
                onDecode: { code in
                    Task { await viewModel.submitScannedCode(code) }
                },
                onRejected: { _ in
                    // The scanner preserves live scanning on a
                    // rejected payload so a later valid QR still
                    // completes. We intentionally do NOT flash a
                    // banner here — real camera feeds see many
                    // non-Catlaser codes, and noisy feedback would
                    // punish the user for normal behaviour.
                },
            )
            .ignoresSafeArea()
            #else
            Text(PairingStrings.scanningPrompt)
                .foregroundStyle(.white)
            #endif

            VStack(spacing: 12) {
                Text(PairingStrings.scanningPrompt)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text(PairingStrings.scanningHint)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                Button(PairingStrings.manualEntryButton) {
                    viewModel.switchToManualEntry()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white)
            }
            .padding(.bottom, 32)
        }
    }

    private func manualEntryView(draft: String) -> some View {
        VStack(spacing: 16) {
            Text(PairingStrings.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            TextField(
                PairingStrings.manualEntryPlaceholder,
                text: Binding(
                    get: { draft },
                    set: { viewModel.setManualDraft($0) },
                ),
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .padding()
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)

            HStack(spacing: 12) {
                Button(PairingStrings.scanInsteadButton) {
                    Task { await viewModel.switchToScanner() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white)

                Button(PairingStrings.manualSubmitButton) {
                    Task { await viewModel.submitManualCode() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: 420)
        .padding()
    }

    private func permissionView(status: CameraPermissionStatus) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "camera")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)
            Text(permissionTitle(status))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(permissionSubtitle(status))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                switch status {
                case .notDetermined:
                    Button(PairingStrings.permissionRequestButton) {
                        Task { await viewModel.requestCameraPermission() }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                case .denied, .restricted:
                    #if canImport(UIKit) && os(iOS)
                    Button(PairingStrings.openSettingsButton) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    #endif
                    Button(PairingStrings.manualEntryButton) {
                        viewModel.switchToManualEntry()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                case .authorized:
                    // Shouldn't reach here — if authorised the VM
                    // transitions to .scanning. Defensive fallback
                    // is a Retry that re-checks permission.
                    Button(PairingStrings.retryButton) {
                        Task { await viewModel.switchToScanner() }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: 420)
        .padding()
    }

    private func pairedView(device: PairedDevice) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(PairingStrings.pairedTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(deviceLabel(device))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
            Text(PairingStrings.connectionStateLabel(viewModel.connectionState))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
            Button(PairingStrings.unpairButton) {
                Task { await viewModel.unpair() }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
        }
        .frame(maxWidth: 420)
        .padding()
    }

    private func deviceLabel(_ device: PairedDevice) -> String {
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? device.id : name
    }

    private func failedView(error: PairingError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(PairingStrings.errorMessage(for: error))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button(PairingStrings.dismissButton) {
                    Task { await viewModel.dismissError() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: 420)
        .padding()
    }

    private func permissionTitle(_ status: CameraPermissionStatus) -> String {
        switch status {
        case .notDetermined, .authorized: PairingStrings.permissionNeededTitle
        case .denied: PairingStrings.permissionDeniedTitle
        case .restricted: PairingStrings.permissionRestrictedTitle
        }
    }

    private func permissionSubtitle(_ status: CameraPermissionStatus) -> String {
        switch status {
        case .notDetermined, .authorized: PairingStrings.permissionNeededSubtitle
        case .denied: PairingStrings.permissionDeniedSubtitle
        case .restricted: PairingStrings.permissionRestrictedSubtitle
        }
    }
}
#endif
