import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var audio = AudioController()

    var body: some View {
        ZStack {
            Color.stage.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        display
                        if let message = audio.statusMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Color.record)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        directionPicker
                        speedControl
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

                transport
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { audio.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            audio.refreshPermission()
        }
        .onChange(of: audio.direction) { _, _ in
            audio.directionChanged()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Audio Reverser")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .foregroundStyle(Color.ink)
                if audio.isRecording {
                    RecordingDot()
                        .accessibilityLabel("Recording")
                }
            }
            Text("Record a clip. Play it forward, backward, or at another speed.")
                .font(.subheadline)
                .foregroundStyle(Color.mute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var display: some View {
        VStack(alignment: .leading, spacing: 14) {
            if audio.permission == .denied {
                deniedDisplay
            } else if audio.isRecording {
                recordingDisplay
            } else if audio.isReversing {
                reversingDisplay
            } else if audio.hasClip {
                readyDisplay
            } else {
                emptyDisplay
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .frame(minHeight: 196)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.panel)
        )
    }

    private var emptyDisplay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(Color.amber)
            Text("Nothing recorded yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("Use Record, then play the latest take normally, in reverse, or at a speed from 0.1× to 3.0×.")
                .font(.subheadline)
                .foregroundStyle(Color.mute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deniedDisplay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.system(size: 28))
                .foregroundStyle(Color.record)
            Text("Microphone access is off")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("Audio Reverser needs the microphone to record. Allow access in Settings, then come back and record a clip.")
                .font(.subheadline)
                .foregroundStyle(Color.mute)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.amber)
            .padding(.top, 4)
        }
    }

    private var recordingDisplay: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RecordingDot()
                Text("Recording")
                    .font(.headline)
                    .foregroundStyle(Color.record)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording")
            Text(clock(audio.recordingElapsed))
                .font(.system(size: 48, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.ink)
                .monospacedDigit()
            LevelMeter(level: audio.level)
            Text("Tap stop when you have the take you want.")
                .font(.subheadline)
                .foregroundStyle(Color.mute)
        }
    }

    private var reversingDisplay: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView()
                .tint(Color.amber)
            Text("Reversing samples…")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("The clip is being flipped in time so reverse playback doesn’t rely on a negative rate.")
                .font(.subheadline)
                .foregroundStyle(Color.mute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readyDisplay: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(audio.isPlaying ? "Playing" : "Latest clip")
                .font(.headline)
                .foregroundStyle(audio.isPlaying ? Color.amber : Color.mute)
            Text(clock(audio.clipDuration ?? 0))
                .font(.system(size: 48, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.ink)
                .monospacedDigit()
            Text(playbackCaption)
                .font(.subheadline)
                .foregroundStyle(Color.mute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var playbackCaption: String {
        let speed = String(format: "%.1f×", audio.speed)
        if audio.isPlaying {
            return "\(audio.direction.label) · \(speed)"
        }
        return "Play it \(audio.direction.label.lowercased()) at \(speed). Speed can change while it plays."
    }

    private var directionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Direction")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
            Picker("Direction", selection: $audio.direction) {
                ForEach(PlaybackDirection.allCases) { direction in
                    Text(direction.label).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .disabled(audio.isReversing)
        }
    }

    private var speedControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(String(format: "%.1f×", audio.speed))
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.amber)
                    .monospacedDigit()
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(String(format: "%.1f times", audio.speed))
            }
            Slider(value: $audio.speed, in: 0.1...3.0, step: 0.1) {
                Text("Speed")
            }
            .tint(Color.amber)
            .accessibilityValue(String(format: "%.1f times", audio.speed))
            HStack {
                Text("0.1×")
                Spacer()
                Text("3.0×")
            }
            .font(.caption)
            .foregroundStyle(Color.mute)
            Text("Applies to normal and reverse. Pitch stays put.")
                .font(.caption)
                .foregroundStyle(Color.mute)
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            TransportButton(
                title: audio.isRecording ? "Stop" : "Record",
                systemImage: audio.isRecording ? "stop.fill" : "mic.fill",
                tint: Color.record,
                prominent: audio.isRecording,
                disabled: audio.permission == .denied || audio.isReversing
            ) {
                Task { await audio.toggleRecording() }
            }
            .accessibilityLabel(audio.isRecording ? "Stop recording" : "Record")

            TransportButton(
                title: audio.isPlaying ? "Stop" : "Play",
                systemImage: audio.isPlaying ? "stop.fill" : "play.fill",
                tint: Color.amber,
                prominent: !audio.isPlaying,
                disabled: !audio.hasClip || audio.isRecording || audio.isReversing
            ) {
                audio.togglePlayback()
            }
            .accessibilityLabel(audio.isPlaying ? "Stop playback" : "Play")
        }
    }

    private func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct TransportButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let prominent: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(prominent ? Color.stage : tint)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(prominent ? tint : Color.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(prominent ? 0 : 0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.38 : 1)
    }
}

private struct RecordingDot: View {
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Color.record)
            .frame(width: 10, height: 10)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Color.record)
                    .frame(width: max(8, geo.size.width * CGFloat(min(1, level))))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Input level")
    }
}

private extension Color {
    static let stage = Color(red: 0.067, green: 0.063, blue: 0.055)
    static let panel = Color(red: 0.118, green: 0.110, blue: 0.098)
    static let ink = Color(red: 0.957, green: 0.941, blue: 0.902)
    static let mute = Color(red: 0.604, green: 0.576, blue: 0.533)
    static let amber = Color(red: 0.910, green: 0.647, blue: 0.294)
    static let record = Color(red: 0.886, green: 0.239, blue: 0.239)
}
