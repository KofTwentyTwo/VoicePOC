import SwiftUI

/// A translucent always-on-top HUD showing JARVIS's current state.
///
/// Visual:
///   - Centered orb that pulses in size + glow with TTS intensity
///   - Color: cyan (listening) / amber (thinking) / magenta (speaking) / dim gray (idle)
///   - Two caption rows: last user utterance + last JARVIS response
///   - A small state label across the top
///
/// "Max Headroom for JARVIS" — minimalist but unmistakably alive.
public struct JarvisHUDView: View {
    @Bindable public var state: JarvisHUDState

    public init(state: JarvisHUDState) {
        self.state = state
    }

    private var modeColor: Color {
        switch state.mode {
        case .idle:      return Color(red: 0.20, green: 0.20, blue: 0.22)
        case .listening: return Color(red: 0.20, green: 0.95, blue: 1.00)
        case .thinking:  return Color(red: 1.00, green: 0.75, blue: 0.25)
        case .speaking:  return Color(red: 1.00, green: 0.30, blue: 0.80)
        }
    }

    private var modeLabel: String {
        switch state.mode {
        case .idle:      return "IDLE — press F1 to talk"
        case .listening: return "LISTENING"
        case .thinking:  return "THINKING"
        case .speaking:  return "SPEAKING"
        }
    }

    public var body: some View {
        ZStack {
            // Background panel: dark + subtle grid feel
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(modeColor.opacity(0.45), lineWidth: 1.2)
                )
                .shadow(color: modeColor.opacity(0.5), radius: 20)

            VStack(spacing: 14) {
                // State label
                Text(modeLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(2.5)
                    .foregroundStyle(modeColor)
                    .padding(.top, 14)

                // Animated orb
                ZStack {
                    // Outer glow (intensity drives radius)
                    Circle()
                        .fill(modeColor.opacity(0.35))
                        .frame(width: 130 + CGFloat(state.intensity) * 50,
                               height: 130 + CGFloat(state.intensity) * 50)
                        .blur(radius: 18)

                    // Mid ring
                    Circle()
                        .strokeBorder(modeColor.opacity(0.75), lineWidth: 2.5)
                        .frame(width: 110 + CGFloat(state.intensity) * 30,
                               height: 110 + CGFloat(state.intensity) * 30)

                    // Inner orb
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [modeColor.opacity(0.85), modeColor.opacity(0.3), .clear],
                                center: .center,
                                startRadius: 4,
                                endRadius: 70 + CGFloat(state.intensity) * 20
                            )
                        )
                        .frame(width: 90, height: 90)

                    // Scanline shimmer — animates while speaking (Max Headroom touch)
                    if state.mode == .speaking {
                        Rectangle()
                            .fill(modeColor.opacity(0.18))
                            .frame(width: 90, height: 1.5)
                            .offset(y: CGFloat(sin(state.intensity * 12)) * 40)
                            .blendMode(.plusLighter)
                    }
                }
                .frame(height: 160)
                .animation(.easeOut(duration: 0.08), value: state.intensity)
                .animation(.easeInOut(duration: 0.3), value: state.mode)

                // Captions
                VStack(alignment: .leading, spacing: 6) {
                    captionRow(icon: "▸", color: .white.opacity(0.6),
                               label: "you", text: state.lastUtterance)
                    captionRow(icon: "◂", color: modeColor.opacity(0.9),
                               label: "jarvis", text: state.lastResponse)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 360, height: 320)
    }

    @ViewBuilder
    private func captionRow(icon: String, color: Color, label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(icon)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 12, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(color.opacity(0.7))
                Text(text.isEmpty ? "—" : text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(text.isEmpty ? 0.3 : 0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
    }
}
