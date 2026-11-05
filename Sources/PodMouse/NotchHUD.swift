import AppKit
import PodMouseCore
import SwiftUI

/// What the notch is showing.
enum HUDContent: Equatable {
    case hidden
    case status(title: String, subtitle: String?, battery: Int?)
    case calibration(step: Calibrator.Step, progress: Double, mode: ControlMode, settling: Bool)
}

final class HUDState: ObservableObject {
    @Published var content = HUDContent.hidden
    /// How much of the top of the screen to stay clear of: the notch or the menu bar.
    @Published var notchHeight: CGFloat = 32
    /// The body at rest: the real notch, or nothing at the top of a screen without one.
    @Published var closedSize = CGSize(width: 185, height: 32)
}

/// A panel that grows out of the MacBook notch. It never takes clicks or focus.
final class NotchHUD {
    private let state = HUDState()
    private let light: AuraLight
    private let panel = OverlayPanel(size: NotchHUD.size)
    private var hideWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?
    private var calibration: (step: Calibrator.Step, progress: Double)?

    static let size = CGSize(width: 560, height: 380)
    private static let statusDuration: TimeInterval = 2.6
    private static let warmUpDuration: TimeInterval = 0.5
    /// A hide straight after a show never reaches the renderer, so it has no collapse to report.
    private static let collapseLimit: TimeInterval = 1.5

    init(airpods: AirPodsScene, light: AuraLight) {
        self.light = light
        var view = HUDView(state: state, airpods: airpods, light: light)
        view.onSettled = { [weak self] in self?.leaveScreen() }
        let host = NSHostingView(rootView: view)
        // The panel keeps its size, so content updates must not reach back into window layout.
        host.sizingOptions = []
        panel.contentView = host
        place()
        DispatchQueue.main.async { self.warmUp() }
    }

    /// A showing nobody can see, while nothing depends on the main thread yet: the first real
    /// one would otherwise build its views and pipelines with the pointer waiting behind it.
    private func warmUp() {
        let rehearsal = [
            HUDContent.status(title: "AirPods", subtitle: "Connected", battery: 100),
            .calibration(step: .sweepSides, progress: 0.5, mode: .hand, settling: false),
        ]
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        for (index, content) in rehearsal.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmUpDuration * Double(index)) { [weak self] in
                guard let self, panel.alphaValue == 0 else { return }
                state.content = content
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmUpDuration * Double(rehearsal.count)) { [weak self] in
            guard let self, panel.alphaValue == 0 else { return }
            state.content = .hidden
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    func showStatus(title: String, subtitle: String?, battery: Int?) {
        if let calibration, calibration.step == .sweepUpDown, calibration.progress > 0.85 {
            light.pulse(.success)
        }
        calibration = nil
        present(.status(title: title, subtitle: subtitle, battery: battery))
        scheduleHide()
    }

    func showCalibration(step: Calibrator.Step, progress: Double, mode: ControlMode, settling: Bool = false) {
        hideWork?.cancel()
        if let calibration, step.rawValue > calibration.step.rawValue { light.pulse(.step) }
        calibration = (step, progress)
        present(.calibration(step: step, progress: progress, mode: mode, settling: settling))
    }

    func hide() {
        hideWork?.cancel()
        calibration = nil
        collapse()
    }

    /// Runs at 50 Hz during calibration, so the window is left alone unless it's off screen.
    private func present(_ content: HUDContent) {
        orderOutWork?.cancel()
        panel.alphaValue = 1
        if !panel.isVisible {
            place()
            panel.orderFrontRegardless()
        }
        light.setProgress(HUDView.progress(of: content))
        if state.content != content { state.content = content }
    }

    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let top = screen.safeAreaInsets.top
        state.notchHeight = max(top, 28)
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.closedSize = CGSize(width: screen.frame.width - left.width - right.width, height: top)
        } else {
            state.closedSize = CGSize(width: 120, height: 0)
        }
        panel.setFrameTopLeftPoint(CGPoint(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY))
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusDuration, execute: work)
    }

    private func collapse() {
        guard state.content != .hidden else { return }
        state.content = .hidden
        light.setProgress(nil)
        let work = DispatchWorkItem { [weak self] in self?.leaveScreen() }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseLimit, execute: work)
    }

    /// Once the body has closed the panel goes, so the light and SceneKit idle. The body also
    /// settles when it shrinks from calibration to a status, and may be reopening by now.
    private func leaveScreen() {
        guard state.content == .hidden else { return }
        orderOutWork?.cancel()
        panel.orderOut(nil)
    }
}

struct HUDView: View {
    /// How far through calibration, or nil when the HUD isn't calibrating.
    static func progress(of content: HUDContent) -> Double? {
        guard case .calibration(let step, let progress, _, _) = content else { return nil }
        return (Double(step.rawValue) + progress) / 3
    }

    /// The case view stays this size for the panel's life and frames with its camera alone,
    /// because making or resizing an SCNView stalls the main thread the pointer runs on.
    private static let caseBox = CGSize(width: 380, height: 270)
    /// Where each framing puts the case, in the case view.
    private static let statusCase = CGPoint(x: 52, y: 66)
    private static let calibrationCase = CGPoint(x: 190, y: 112)
    /// Light gathers behind the case and the rest of the body stays black, like the hardware.
    private static let blobStrength = 0.5

    @ObservedObject var state: HUDState
    let airpods: AirPodsScene
    let light: AuraLight
    /// Called once the body has finished closing.
    var onSettled: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            AuraView(light: light, stage: stage, onSettled: onSettled)
            AirPodsView(airpods: airpods, framing: framing)
                .frame(width: Self.caseBox.width, height: Self.caseBox.height)
                .opacity(isHidden ? 0 : 1)
                .animation(.easeOut(duration: isHidden ? 0.1 : 0.24), value: isHidden)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isHidden: Bool { state.content == .hidden }

    /// Which view is up, without the progress that changes at 50 Hz.
    private enum Phase: Hashable {
        case hidden
        case status(String, String?, Int?)
        case calibration
    }

    private var phase: Phase {
        switch state.content {
        case .hidden: return .hidden
        case .status(let title, let subtitle, let battery): return .status(title, subtitle, battery)
        case .calibration: return .calibration
        }
    }

    private var framing: AirPodsFraming {
        if case .calibration = state.content { return .hudCalibration }
        return .hudStatus
    }

    /// Worked out from the content alone, so stills get the same light as the panel.
    private var stage: AuraStage {
        let casePoint = framing == .hudCalibration ? Self.calibrationCase : Self.statusCase
        var stage = AuraStage()
        stage.blobCenter = CGPoint(
            x: ((NotchHUD.size.width - Self.caseBox.width) / 2 + casePoint.x) / NotchHUD.size.width,
            y: casePoint.y / NotchHUD.size.height
        )
        switch state.content {
        case .hidden:
            stage.notch = state.closedSize
            stage.notchRadius = 10
            stage.blobRadius = 60
            stage.blobStrength = 0
            stage.glow = 0
        case .status:
            stage.notch = CGSize(width: StatusRow.width, height: state.notchHeight + 62)
            stage.notchRadius = 24
            stage.blobRadius = 40
            stage.blobStrength = Self.blobStrength
        case .calibration:
            stage.notch = CGSize(width: CalibrationCard.width, height: state.notchHeight + 232)
            stage.notchRadius = 30
            stage.blobRadius = 72
            stage.blobStrength = Self.blobStrength
        }
        return stage
    }

    /// In once the body has mostly opened and out at once, so text never spills past the black.
    private var entrance: AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity.animation(.easeOut(duration: 0.2).delay(0.14))
            : .opacity.combined(with: .offset(y: -6)).animation(Theme.spring.delay(0.16))
        return .asymmetric(insertion: insertion, removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    private var content: some View {
        Group {
            switch state.content {
            case .hidden:
                EmptyView()
            case .status(let title, let subtitle, let battery):
                StatusRow(title: title, subtitle: subtitle, battery: battery, center: Self.statusCase.y)
                    .id(phase)
                    .transition(entrance)
            case .calibration(let step, let progress, let mode, let settling):
                CalibrationCard(step: step, progress: progress, mode: mode, settling: settling)
                    .transition(entrance)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.default, value: phase)
    }
}

/// Text beside the case, which the persistent case view draws at the left of the body.
private struct StatusRow: View {
    static let width: CGFloat = 340

    let title: String
    let subtitle: String?
    let battery: Int?
    /// Level with the case.
    let center: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.pod(14, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(.pod(11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let battery { BatteryRing(level: battery) }
        }
        .padding(.leading, 72)
        .padding(.trailing, 22)
        .frame(width: Self.width, height: 62)
        .padding(.top, center - 31)
    }
}

private struct BatteryRing: View {
    let level: Int

    private var stroke: AnyShapeStyle {
        level <= 20
            ? AnyShapeStyle(Theme.aurora[4])
            : AnyShapeStyle(AngularGradient(colors: Theme.aurora + [Theme.aurora[0]], center: .center))
    }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: 3)
            Circle()
                .trim(from: 0, to: Double(level) / 100)
                .stroke(stroke, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(level)")
                .font(.pod(10.5, .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
    }
}

/// A step that fills with light, then folds into a check mark.
private struct StepSegment: View {
    private static let length: CGFloat = 46
    private static let badge: CGFloat = 18

    let isDone: Bool
    let fill: Double
    let isCalm: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.16))
            Rectangle()
                .fill(LinearGradient(colors: Theme.aurora, startPoint: .leading, endPoint: .trailing))
                .frame(width: isDone ? Self.badge : Self.length * fill)
                .opacity(isCalm ? 0.5 : 1)
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: Self.badge, height: Self.badge)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(width: isDone ? Self.badge : Self.length, height: isDone ? Self.badge : 4)
        .clipShape(Capsule())
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Theme.snap, value: isDone)
        .animation(.easeInOut(duration: 0.3), value: isCalm)
    }
}

/// Everything under the case, which the persistent case view draws at the top of the body.
private struct CalibrationCard: View {
    static let width: CGFloat = 380
    /// Clear of the bottom of the case, whatever the height of the notch.
    private static let top: CGFloat = 174

    let step: Calibrator.Step
    let progress: Double
    let mode: ControlMode
    let settling: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    StepSegment(isDone: index < step.rawValue, fill: fill(of: index), isCalm: settling)
                }
            }
            .frame(height: 18)

            ZStack {
                Text(title)
                    .font(.pod(15, .semibold))
                    .foregroundStyle(.white)
                    .id(title)
                    .transition(.opacity)
            }
            .padding(.top, 9)
            .animation(.easeInOut(duration: 0.24), value: title)

            ZStack(alignment: .top) {
                Text(subtitle)
                    .font(.pod(12, .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .id(subtitle)
                    .transition(.opacity)
            }
            .padding(.top, 3)
            .animation(.easeInOut(duration: 0.24), value: subtitle)
        }
        .frame(width: Self.width - 48)
        .padding(.top, Self.top)
    }

    private func fill(of index: Int) -> Double {
        index < step.rawValue ? 1 : index == step.rawValue ? progress : 0
    }

    private var title: String {
        if settling { return "Hold still" }
        switch step {
        case .holdStill, .done: return "Hold still"
        case .sweepSides: return "Left and right, 3 times"
        case .sweepUpDown: return "Up and down, 3 times"
        }
    }

    private var subtitle: String {
        if settling { return "Stop for a moment." }
        switch (step, mode) {
        case (.holdStill, .hand), (.done, .hand): return "Hold the case like a laser pointer, aimed at the screen."
        case (.holdStill, .head), (.done, .head): return "Look at the middle of the screen."
        case (.sweepSides, .hand): return "Move only your wrist, smoothly. Start to the right."
        case (.sweepSides, .head): return "Turn your head smoothly. Start to the right."
        case (.sweepUpDown, .hand): return "Move only your wrist, smoothly. Start upward."
        case (.sweepUpDown, .head): return "Nod slowly. Start upward."
        }
    }
}
