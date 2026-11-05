import AppKit
import CoreMotion
import PodMouseCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 18) {
                PodSegments(selection: $model.prefs.mode, options: [
                    (.hand, "Case in hand"),
                    (.head, "In your ears"),
                ])

                if let problem {
                    ProblemCard(problem: problem)
                        .transition(.podCard)
                }

                VStack(spacing: 6) {
                    PodSlider(title: "Pointer speed", value: $model.prefs.sensitivity, range: 0.4...2.5) {
                        $0.formatted(.number.precision(.fractionLength(1))) + "×"
                    }
                    if model.prefs.mode == .hand {
                        TapSlider(threshold: $model.prefs.tapThreshold, live: model.live)
                            .transition(.podRow)
                    }
                }

                VStack(spacing: 10) {
                    Toggle("Click by resting on buttons", isOn: $model.prefs.dwellEnabled)
                        .toggleStyle(PodToggleStyle())
                    HStack(spacing: 6) {
                        Text("Reverse direction")
                            .font(.pod(12.5))
                            .foregroundStyle(.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("Horizontal", isOn: $model.prefs.invertX)
                        Toggle("Vertical", isOn: $model.prefs.invertY)
                    }
                    .toggleStyle(ChipToggleStyle())
                    if model.prefs.mode == .hand {
                        Toggle("Drag with a left twist", isOn: $model.prefs.twistDrags)
                            .toggleStyle(PodToggleStyle())
                            .transition(.podRow)
                    }
                }

                GestureList(mode: model.prefs.mode, twistDrags: model.prefs.twistDrags)

                HStack {
                    Button(model.needsCalibration ? "Set up…" : "Recalibrate") {
                        model.startCalibration()
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .animation(.pod, value: problem?.text)
        }
        .frame(width: 320)
        .background(.surface)
    }

    private var hero: some View {
        HeroStage(light: model.light, airpods: model.airpods, blobRadius: 88, blobY: 0.62, caseInset: 54)
            .frame(height: 206)
            .overlay(alignment: .top) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PodMouse")
                            .font(.pod(18, .bold))
                            .tracking(-0.6)
                            .foregroundStyle(.ink)
                        HStack(spacing: 6) {
                            MoodDot(mood: AuraMood(isOn: model.isOn, isPaused: model.isPaused, isCalibrating: model.isCalibrating, isReceivingMotion: model.isReceivingMotion))
                            Text(statusText)
                                .font(.pod(11.5))
                                .foregroundStyle(.ink2)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    Toggle("PodMouse", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                        .toggleStyle(PowerToggleStyle())
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
    }

    private var statusText: String {
        if !model.isOn { return "Off" }
        if model.isCalibrating { return "Calibrating" }
        if model.isPaused { return "Paused" }
        if model.isReceivingMotion { return model.headphones?.name ?? "Connected" }
        return "Waiting for AirPods"
    }

    /// Only the first thing that's wrong: each fix can change what comes next.
    private var problem: Problem? {
        if !model.hasAccessibility {
            return Problem(
                text: "PodMouse needs Accessibility to move the pointer.",
                action: "Open Settings",
                perform: model.openAccessibilitySettings
            )
        }
        if model.motionAuthorization == .denied || model.motionAuthorization == .restricted {
            return Problem(
                text: "Motion access is off for PodMouse in Privacy & Security.",
                action: nil,
                perform: nil
            )
        }
        guard model.isOn, !model.isReceivingMotion else { return nil }
        if model.prefs.mode == .hand {
            return Problem(
                text: "No motion yet. Open the case lid and turn off Automatic Ear Detection in your AirPods settings.",
                action: "Open Bluetooth Settings",
                perform: model.openBluetoothSettings
            )
        }
        if !model.isOnHeadphones {
            return Problem(
                text: "AirPods only send motion while they're the Mac's sound output.",
                action: "Switch sound to AirPods",
                perform: model.switchSoundToHeadphones
            )
        }
        return Problem(text: "No motion yet. Wear both AirPods.", action: nil, perform: nil)
    }
}

private struct Problem {
    let text: String
    let action: String?
    let perform: (() -> Void)?
}

private struct ProblemCard: View {
    let problem: Problem

    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    private static let amber = Theme.aurora[4]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(problem.text)
                .font(.pod(12))
                .lineSpacing(2)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let action = problem.action, let perform = problem.perform {
                Button(action, action: perform)
                    .buttonStyle(InkPillButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            ZStack {
                Self.shape.fill(Self.amber).blur(radius: 16).opacity(0.3).offset(y: 5)
                Self.shape.fill(.surface)
                Self.shape.fill(.raised)
                Self.shape.fill(RadialGradient(colors: [Self.amber.opacity(0.24), Self.amber.opacity(0.05)], center: .topLeading, startRadius: 0, endRadius: 260))
            }
        }
    }
}

/// The knob is the threshold and the track is the meter: a tap fills it from the left,
/// and one that clears the knob lights up, so the threshold can be set by eye.
private struct TapSlider: View {
    @Binding var threshold: Double
    let live: LiveSignals

    var body: some View {
        PodSlider(title: "Tap strength", value: $threshold, range: 0.2...1.0) {
            $0.formatted(.number.precision(.fractionLength(2)))
        } fill: { scale in
            JoltFill(live: live, threshold: threshold, scale: scale)
        }
    }
}

/// Alone in observing the live signals, so jolts redraw this and not the menu.
private struct JoltFill: View {
    @ObservedObject var live: LiveSignals
    let threshold: Double
    let scale: TrackScale

    var body: some View {
        let lit = live.jolt > threshold
        ZStack(alignment: .leading) {
            Capsule().fill(.ink3)
            AuroraFill(end: scale.width)
                .opacity(lit ? 1 : 0)
                .animation(.podFade, value: lit)
        }
        .mask(alignment: .leading) {
            Rectangle().frame(width: live.jolt > scale.range.lowerBound ? scale.x(live.jolt) : 0)
        }
        .background {
            // Soft and cheap: this redraws with every motion frame, so it's a gradient, not a blur.
            Circle()
                .fill(RadialGradient(colors: [Theme.aurora[1].opacity(0.55), .clear], center: .center, startRadius: 4, endRadius: 22))
                .frame(width: 44, height: 44)
                .position(x: scale.x(threshold), y: 2)
                .opacity(lit ? 1 : 0)
                .animation(.podFade, value: lit)
        }
    }
}

private struct MoodDot: View {
    let mood: AuraMood

    private var tint: Color? {
        switch mood {
        case .off: return nil
        case .searching: return Theme.aurora[1]
        case .connected: return Theme.aurora[2]
        case .calibrating: return Theme.aurora[0]
        case .paused: return Theme.aurora[4]
        }
    }

    var body: some View {
        Circle()
            .fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.ink3))
            .frame(width: 6, height: 6)
            .shadow(color: (tint ?? .clear).opacity(0.7), radius: 2)
            .animation(.podFade, value: mood)
            .accessibilityHidden(true)
    }
}

/// The case floating in the light, which dissolves into the surface below it.
private struct HeroStage: View {
    let light: AuraLight
    let airpods: AirPodsScene
    let blobRadius: CGFloat
    /// Where the case sits on the stage, as a fraction of its height.
    let blobY: CGFloat
    /// Room above the case, for what sits over the stage.
    let caseInset: CGFloat

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            AuraView(light: light, stage: AuraStage(notch: nil, blobCenter: CGPoint(x: 0.5, y: blobY), blobRadius: blobRadius, blobStrength: scheme == .dark ? 0.8 : 1, onDark: scheme == .dark))
            Rectangle()
                .fill(.surface)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0.68), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
            AirPodsView(airpods: airpods)
                .padding(.top, caseInset)
        }
    }
}

private struct GestureList: View {
    let mode: ControlMode
    let twistDrags: Bool

    private var rows: [(String, String)] {
        switch mode {
        case .hand:
            return [
                ("Hold still, tap the case", "Click"),
                ("Twist right and back", "Right click"),
            ] + (twistDrags ? [("Twist left and back", "Drag")] : []) + [
                ("⌃⌥T", "Pause"),
            ]
        case .head:
            return [
                ("Nod or press stem", "Click"),
                ("Press twice", "Right click"),
                ("Shake your head", "Pause"),
                ("⌃⌥C", "Center pointer"),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 12) {
                    if row.0.hasPrefix("⌃") {
                        Keycaps(keys: row.0)
                    } else {
                        Text(row.0).foregroundStyle(.ink2)
                    }
                    Spacer(minLength: 0)
                    Text(row.1).foregroundStyle(.ink)
                }
                .frame(minHeight: 18)
                .accessibilityElement(children: .combine)
                .transition(.podRow)
            }
        }
        .font(.pod(11.5))
        .animation(.pod, value: twistDrags)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let onDone: () -> Void

    @State private var appeared = false
    @Environment(\.stillRendering) private var still

    private var shown: Bool { appeared || still }

    var body: some View {
        VStack(spacing: 0) {
            HeroStage(light: model.light, airpods: model.airpods, blobRadius: 124, blobY: 0.56, caseInset: 26)
                .frame(height: 244)

            VStack(spacing: 4) {
                Text("PodMouse")
                    .font(.pod(40, .bold))
                    .tracking(-1.6)
                    .foregroundStyle(.ink)
                Text("Your AirPods case is now a mouse.")
                    .font(.pod(15))
                    .tracking(-0.2)
                    .foregroundStyle(.ink2)
            }
            .rise(0, shown: shown)
            .padding(.top, -8)

            VStack(alignment: .leading, spacing: 13) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    WelcomeRow(symbol: step.symbol, glow: Theme.aurora[index % Theme.aurora.count], title: step.title, detail: step.detail)
                        .rise(index + 1, shown: shown)
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 36)

            Button {
                onDone()
                model.startCalibration()
            } label: {
                Text("Get Started")
                    .frame(minWidth: 148)
            }
            .buttonStyle(InkPillButtonStyle(font: .pod(14, .semibold), height: 46))
            .background { AuroraGlow().padding(.horizontal, 10).padding(.vertical, 4).opacity(0.7).offset(y: 6) }
            .rise(steps.count + 1, shown: shown)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .frame(width: 440)
        .background(.surface)
        .ignoresSafeArea(edges: .top)
        .onAppear {
            appeared = true
            // The app is still off here, which would leave the hero without colour.
            if !still { show(.connected) }
        }
        .task {
            guard !still else { return }
            try? await Task.sleep(for: .seconds(0.7))
            if !Task.isCancelled { model.airpods.setLidOpen(true) }
        }
        .onDisappear {
            model.airpods.setLidOpen(model.isOn)
            show(AuraMood(isOn: model.isOn, isPaused: model.isPaused, isCalibrating: model.isCalibrating, isReceivingMotion: model.isReceivingMotion))
        }
    }

    private func show(_ mood: AuraMood) {
        model.light.set(mood: mood)
        model.airpods.setMood(mood)
    }

    private var steps: [(symbol: String, title: String, detail: String)] {
        [
            ("hand.point.up.left", "Hold it like a laser pointer", "Rest your elbow, move only your wrist, in short smooth moves."),
            ("accessibility", "Allow Accessibility", "To move the pointer and click for you."),
            ("gyroscope", "Allow Motion", "Processed on your Mac, never sent anywhere."),
            ("ear.badge.waveform", "Turn off Automatic Ear Detection", "In AirPods settings, so motion keeps flowing."),
            ("airpods.gen4", "Keep the lid open", "A few millimetres is enough. Snapping it shut disconnects them."),
        ]
    }
}

private extension View {
    /// One beat of the welcome screen's entrance, which ends visible so stills aren't blank.
    func rise(_ beat: Int, shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || Theme.reduceMotion ? 0 : 16)
            .animation(.pod.delay(0.1 + Double(beat) * 0.065), value: shown)
    }
}

private struct WelcomeRow: View {
    let symbol: String
    /// Each row sits in its own hue of the light, while the symbol stays ink.
    let glow: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.ink)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(RadialGradient(colors: [glow.opacity(0.34), glow.opacity(0)], center: .center, startRadius: 2, endRadius: 26))
                        .frame(width: 52, height: 52)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.pod(13.5, .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(.ink)
                Text(detail)
                    .font(.pod(12))
                    .foregroundStyle(.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
