import ReplayKit
import SwiftUI

/// Wraps Apple's `RPSystemBroadcastPickerView`, the only public way for an
/// app to start a system-wide broadcast. The system — not our app — shows
/// the sheet where the user confirms and taps "Start Broadcast", so capture
/// can never begin silently.
struct BroadcastPicker: UIViewRepresentable {
    /// Bundle ID of our Broadcast Upload Extension, so the sheet preselects it.
    var preferredExtension: String?
    /// Hides the system glyph when the picker is layered over our own label.
    var hidesGlyph = false

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        configure(picker)
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        configure(picker)
    }

    private func configure(_ picker: RPSystemBroadcastPickerView) {
        picker.preferredExtension = preferredExtension
        picker.tintColor = hidesGlyph ? .clear : .white
    }
}

/// "START COACHING": our label with the system picker layered on top, so a
/// tap anywhere on the button reaches Apple's control. No private views are
/// touched.
struct StartCoachingButton: View {
    var preferredExtension: String?
    var isLive: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "record.circle")
                    .font(.title2)
                Text(isLive ? "COACHING ACTIVE" : "START COACHING")
                    .font(.headline.weight(.heavy))
                    .tracking(1.5)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(isLive ? Color.red.gradient : Color.accentColor.gradient, in: Capsule())
            .allowsHitTesting(false)

            BroadcastPicker(preferredExtension: preferredExtension, hidesGlyph: true)
                .frame(maxWidth: .infinity, minHeight: 64)
                .accessibilityLabel(isLive ? "Stop or manage coaching broadcast" : "Start coaching")
        }
        .frame(height: 64)
    }
}
