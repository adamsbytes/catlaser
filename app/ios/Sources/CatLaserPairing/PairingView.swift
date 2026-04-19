#if canImport(SwiftUI)
import CatLaserDesign
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var errorFocus: Bool

    public init(viewModel: PairingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            SemanticColor.background.ignoresSafeArea()
            contentView
        }
        .accessibilityID(.pairingRoot)
        .catlaserDynamicTypeBounds()
        .animation(
            CatLaserMotion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: phaseTag,
        )
        .task {
            await viewModel.start()
        }
        .onChange(of: phaseTag) { _, newValue in
            if newValue.hasPrefix("failed") {
                errorFocus = true
                Haptics.error.play()
            } else if newValue == "paired" {
                Haptics.success.play()
            }
        }
    }

    private var phaseTag: String {
        switch viewModel.phase {
        case .checkingExisting: "checkingExisting"
        case let .needsCameraPermission(status): "needsCameraPermission:\(status)"
        case .scanning: "scanning"
        case .manualEntry: "manualEntry"
        case .confirming: "confirming"
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
        case let .confirming(code):
            confirmingView(code: code)
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
                .accessibilityLabel(Text(label ?? PairingStrings.exchangingLabel))
            if let label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(SemanticColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var scanningView: some View {
        ZStack(alignment: .bottom) {
            #if canImport(AVFoundation) && canImport(UIKit) && os(iOS)
            QRScannerView(
                onDecode: { code in
                    Haptics.light.play()
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
            .accessibilityLabel(Text(PairingStrings.scanningPrompt))
            #else
            Text(PairingStrings.scanningPrompt)
                .foregroundStyle(SemanticColor.textPrimary)
            #endif

            VStack(spacing: 12) {
                Text(PairingStrings.scanningPrompt)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .accessibilityHeader()
                Text(PairingStrings.scanningHint)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                Button(PairingStrings.manualEntryButton) {
                    viewModel.switchToManualEntry()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityID(.pairingManualEntryToggle)
                .accessibilityLabel(Text(PairingStrings.manualEntryButton))
            }
            .padding(.bottom, 32)
            .padding(.horizontal, 24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func manualEntryView(draft: String) -> some View {
        VStack(spacing: 16) {
            Text(PairingStrings.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
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
            .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(SemanticColor.separator, lineWidth: 1),
            )
            .foregroundStyle(SemanticColor.textPrimary)
            .accessibilityID(.pairingManualField)
            .accessibilityLabel(Text(PairingStrings.manualEntryPlaceholder))

            HStack(spacing: 12) {
                Button(PairingStrings.scanInsteadButton) {
                    Task { await viewModel.switchToScanner() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(SemanticColor.elevatedFill, in: Capsule())
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityID(.pairingScanInstead)
                .accessibilityLabel(Text(PairingStrings.scanInsteadButton))

                Button(PairingStrings.manualSubmitButton) {
                    Haptics.commit.play()
                    Task { await viewModel.submitManualCode() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(SemanticColor.accent, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityID(.pairingManualSubmit)
                .accessibilityLabel(Text(PairingStrings.manualSubmitButton))
            }
        }
        .frame(maxWidth: 420)
        .padding()
    }

    private func permissionView(status: CameraPermissionStatus) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "camera")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(SemanticColor.textSecondary)
                .accessibilityDecorativeIcon()
            Text(permissionTitle(status))
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(permissionSubtitle(status))
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
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
                    .background(SemanticColor.accent, in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityID(.pairingPermissionRequest)
                    .accessibilityLabel(Text(PairingStrings.permissionRequestButton))
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
                    .background(SemanticColor.elevatedFill, in: Capsule())
                    .foregroundStyle(SemanticColor.textPrimary)
                    .accessibilityID(.pairingOpenSettings)
                    .accessibilityLabel(Text(PairingStrings.openSettingsButton))
                    #endif
                    Button(PairingStrings.manualEntryButton) {
                        viewModel.switchToManualEntry()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(SemanticColor.accent, in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityID(.pairingManualEntryToggle)
                    .accessibilityLabel(Text(PairingStrings.manualEntryButton))
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
                    .background(SemanticColor.accent, in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityID(.pairingRetry)
                    .accessibilityLabel(Text(PairingStrings.retryButton))
                }
            }
        }
        .frame(maxWidth: 420)
        .padding()
    }

    private func confirmingView(code: PairingCode) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(SemanticColor.accent)
                .accessibilityDecorativeIcon()
            Text(PairingStrings.confirmTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityHeader()
            VStack(spacing: 4) {
                Text(PairingStrings.confirmDeviceIDLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SemanticColor.textSecondary)
                    .textCase(.uppercase)
                Text(code.deviceID)
                    .font(.title3.weight(.semibold).monospaced())
                    .foregroundStyle(SemanticColor.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(SemanticColor.groupedBackground, in: RoundedRectangle(cornerRadius: 10))
            }
            Text(PairingStrings.confirmSubtitle)
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.cancelPairingConfirmation() }
                } label: {
                    Text(PairingStrings.confirmCancelButton)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(SemanticColor.elevatedFill, in: Capsule())
                        .foregroundStyle(SemanticColor.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityID(.pairingConfirmCancel)
                .accessibilityLabel(Text(PairingStrings.confirmCancelButton))
                Button {
                    Haptics.commit.play()
                    Task { await viewModel.confirmPairing() }
                } label: {
                    Text(PairingStrings.confirmButton)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(SemanticColor.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityID(.pairingConfirmAccept)
                .accessibilityLabel(Text(PairingStrings.confirmButton))
            }
        }
        .frame(maxWidth: 420)
        .padding()
        .accessibilityElement(children: .contain)
    }

    private func pairedView(device: PairedDevice) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(SemanticColor.success)
                .accessibilityDecorativeIcon()
            Text(PairingStrings.pairedTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityHeader()
            Text(deviceLabel(device))
                .font(.callout)
                .foregroundStyle(SemanticColor.textSecondary)
            Text(PairingStrings.connectionStateLabel(viewModel.connectionState))
                .font(.footnote)
                .foregroundStyle(SemanticColor.textTertiary)
                .accessibilityAddTraits(.updatesFrequently)
            Button(PairingStrings.unpairButton) {
                Haptics.warning.play()
                Task { await viewModel.unpair() }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(SemanticColor.elevatedFill, in: Capsule())
            .foregroundStyle(SemanticColor.textPrimary)
            .accessibilityID(.pairingUnpair)
            .accessibilityLabel(Text(PairingStrings.unpairButton))
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
                .foregroundStyle(SemanticColor.warning)
                .accessibilityDecorativeIcon()
            Text(PairingStrings.errorMessage(for: error))
                .font(.callout)
                .foregroundStyle(SemanticColor.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .accessibilityFocused($errorFocus)
            HStack(spacing: 12) {
                Button(PairingStrings.dismissButton) {
                    Task { await viewModel.dismissError() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(SemanticColor.elevatedFill, in: Capsule())
                .foregroundStyle(SemanticColor.textPrimary)
                .accessibilityID(.pairingDismissError)
                .accessibilityLabel(Text(PairingStrings.dismissButton))
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
