import SwiftUI

/// Live "what is VoicePOC hearing / saying right now?" panel. Polls the
/// JarvisHUDState at 10 Hz and shows:
///   - Current state (idle / listening / thinking / speaking)
///   - Mic RMS as a horizontal bar (so you can see audio is being captured)
///   - VAD probability as a horizontal bar (so you can see speech detection)
///   - Last user transcript (when STT completes)
///   - Streaming JARVIS reply (token-by-token as Ollama generates)
///   - Listening elapsed seconds
public struct JarvisStatusView: View {
    @Bindable public var state: JarvisHUDState

    public init(state: JarvisHUDState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metersSection
            transcriptSection
            responseSection
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 360, idealHeight: 460)
        .background(Color(white: 0.07))
    }

    private var modeColor: Color {
        switch state.mode {
        case .idle:      return Color(white: 0.55)
        case .listening: return Color(red: 0.20, green: 0.95, blue: 1.00)
        case .thinking:  return Color(red: 1.00, green: 0.75, blue: 0.25)
        case .speaking:  return Color(red: 1.00, green: 0.30, blue: 0.80)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VOICEPOC — JARVIS")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(modeColor)
            HStack {
                Text(stateLabel)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(modeColor)
                Spacer()
                if state.mode == .listening {
                    Text(String(format: "%.1fs", state.listeningElapsed))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateLabel: String {
        switch state.mode {
        case .idle:      return "● IDLE  — press F1 to talk"
        case .listening: return "● LISTENING"
        case .thinking:  return "● THINKING"
        case .speaking:  return "● SPEAKING"
        }
    }

    @ViewBuilder
    private var metersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            meter(label: "RMS",
                  value: state.micRMS,
                  scale: 0.3,
                  color: Color(red: 0.20, green: 0.95, blue: 1.00),
                  numericFormat: "%.3f")
            meter(label: "VAD",
                  value: Double(state.vadProbability),
                  scale: 1.0,
                  color: state.vadProbability >= 0.5
                    ? Color(red: 0.20, green: 1.00, blue: 0.40)
                    : Color(white: 0.50),
                  numericFormat: "%.2f")
        }
    }

    @ViewBuilder
    private func meter(label: String, value: Double, scale: Double, color: Color, numericFormat: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.15)).frame(height: 10)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, min(1, value / scale)) * geo.size.width, height: 10)
                }
            }
            .frame(height: 10)
            Text(String(format: numericFormat, value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOU")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            Text(state.lastUtterance.isEmpty ? "—" : state.lastUtterance)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(state.lastUtterance.isEmpty ? Color(white: 0.35) : Color.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.10)))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("JARVIS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(modeColor.opacity(0.9))
                if state.mode == .thinking || state.mode == .speaking {
                    Text("(\(state.streamingTokenCount) chunks)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(state.lastResponse.isEmpty ? "—" : state.lastResponse)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(state.lastResponse.isEmpty ? Color(white: 0.35) : Color.white)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.10)))
                .textSelection(.enabled)
        }
    }
}
