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
    @Published var notchHeight: CGFloat = 32
}

/// A panel that grows out of the MacBook notch. It never takes clicks or focus.
final class NotchHUD {
    private let state = HUDState()
    private let airpods: AirPodsScene
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    private static let size = CGSize(width: 460, height: 320)
    private static let statusDuration: TimeInterval = 2.6

    init(airpods: AirPodsScene) {
        self.airpods = airpods
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(state: state, airpods: airpods))
    }

    func showStatus(title: String, subtitle: String?, battery: Int?) {
        present(.status(title: title, subtitle: subtitle, battery: battery))
        scheduleHide()
    }

    func showCalibration(step: Calibrator.Step, progress: Double, mode: ControlMode, settling: Bool = false) {
        hideWork?.cancel()
        present(.calibration(step: step, progress: progress, mode: mode, settling: settling))
    }

    func hide() {
        hideWork?.cancel()
        state.content = .hidden
    }

    private func present(_ content: HUDContent) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        state.notchHeight = max(screen.safeAreaInsets.top, 28)
        panel.setFrameTopLeftPoint(CGPoint(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY))
        panel.orderFrontRegardless()
        state.content = content
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.state.content = .hidden }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusDuration, execute: work)
    }
}

/// Black like the notch, square at the top so it reads as part of the hardware.
struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct HUDView: View {
    @ObservedObject var state: HUDState
    let airpods: AirPodsScene

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(.black, in: NotchShape(radius: isHidden ? 10 : 22))
                .clipShape(NotchShape(radius: isHidden ? 10 : 22))
                .opacity(isHidden ? 0 : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: state.content)
    }

    private var isHidden: Bool { state.content == .hidden }

    private var size: CGSize {
        switch state.content {
        case .hidden: return CGSize(width: 200, height: state.notchHeight)
        case .status: return CGSize(width: 340, height: state.notchHeight + 58)
        case .calibration: return CGSize(width: 380, height: state.notchHeight + 214)
        }
    }

    @ViewBuilder private var content: some View {
        switch state.content {
        case .hidden:
            EmptyView()
        case .status(let title, let subtitle, let battery):
            StatusRow(title: title, subtitle: subtitle, battery: battery, airpods: airpods)
                .padding(.top, state.notchHeight + 6)
                .padding(.horizontal, 20)
                .transition(.opacity)
        case .calibration(let step, let progress, let mode, let settling):
            CalibrationCard(step: step, progress: progress, mode: mode, settling: settling, airpods: airpods)
                .padding(.top, state.notchHeight + 12)
                .padding(.horizontal, 24)
                .transition(.opacity)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let subtitle: String?
    let battery: Int?
    let airpods: AirPodsScene

    var body: some View {
        HStack(spacing: 12) {
            AirPodsView(airpods: airpods)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 8)
            if let battery { BatteryRing(level: battery) }
        }
    }
}

private struct BatteryRing: View {
    let level: Int

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 3)
            Circle()
                .trim(from: 0, to: Double(level) / 100)
                .stroke(level <= 20 ? Color.orange : Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(level)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
    }
}

private struct CalibrationCard: View {
    let step: Calibrator.Step
    let progress: Double
    let mode: ControlMode
    let settling: Bool
    let airpods: AirPodsScene

    var body: some View {
        VStack(spacing: 8) {
            AirPodsView(airpods: airpods)
                .frame(width: 130, height: 104)

            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .overlay(alignment: .leading) {
                            GeometryReader { bar in
                                Capsule().fill(.white).frame(width: bar.size.width * fill(of: index))
                            }
                        }
                        .frame(width: 26, height: 3)
                }
            }

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 4)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func fill(of index: Int) -> Double {
        index < step.rawValue ? 1 : index == step.rawValue ? progress : 0
    }

    private var title: String {
        if settling { return L("Hold still", "Замрите") }
        switch step {
        case .holdStill, .done: return L("Hold still", "Замрите")
        case .sweepSides: return L("Left and right, 3 times", "Влево-вправо, 3 раза")
        case .sweepUpDown: return L("Up and down, 3 times", "Вверх-вниз, 3 раза")
        }
    }

    private var subtitle: String {
        if settling { return L("Stop for a moment.", "Остановитесь на секунду.") }
        switch (step, mode) {
        case (.holdStill, .hand), (.done, .hand): return L("Hold the case like a laser pointer, aimed at the screen.", "Держите кейс как лазерную указку, направив на экран.")
        case (.holdStill, .head), (.done, .head): return L("Look at the middle of the screen.", "Смотрите в центр экрана.")
        case (.sweepSides, .hand): return L("Move only your wrist, smoothly. Start to the right.", "Плавно, только кистью. Начните вправо.")
        case (.sweepSides, .head): return L("Turn your head smoothly. Start to the right.", "Плавно поворачивайте голову. Начните вправо.")
        case (.sweepUpDown, .hand): return L("Move only your wrist, smoothly. Start upward.", "Плавно, только кистью. Начните вверх.")
        case (.sweepUpDown, .head): return L("Nod slowly. Start upward.", "Медленно кивайте. Начните вверх.")
        }
    }
}

/// The ring that fills around the pointer before a resting click.
final class DwellRing {
    private final class Progress: ObservableObject {
        @Published var value = 0.0
    }

    private struct RingView: View {
        @ObservedObject var progress: Progress

        var body: some View {
            ZStack {
                Circle().stroke(.black.opacity(0.25), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress.value)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(radius: 1)
            }
            .padding(4)
        }
    }

    private static let side: CGFloat = 40
    private let progress = Progress()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RingView(progress: progress))
        return panel
    }()

    /// `point` is in global display coordinates, whose origin is at the top left.
    func show(at point: CGPoint, progress value: Double) {
        guard let height = NSScreen.screens.first?.frame.height else { return }
        panel.setFrameOrigin(CGPoint(x: point.x - Self.side / 2, y: height - point.y - Self.side / 2))
        panel.orderFrontRegardless()
        progress.value = value
    }

    func hide() {
        panel.orderOut(nil)
        progress.value = 0
    }
}
