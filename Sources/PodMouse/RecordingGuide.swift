import AppKit
import SwiftUI

/// The large on-screen card that walks a person through a sensor recording.
final class RecordingGuide {
    private final class State: ObservableObject {
        @Published var step = 0
        @Published var total = 0
        @Published var title = ""
        @Published var detail = ""
        @Published var left = 0
        @Published var duration = 1
    }

    private struct Card: View {
        @ObservedObject var state: State

        var body: some View {
            VStack(spacing: 14) {
                Text(L("Step \(state.step) of \(state.total)", "Шаг \(state.step) из \(state.total)"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(state.title)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(state.detail)
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: Double(state.left) / Double(max(state.duration, 1)))
                        .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: state.left)
                    Text("\(state.left)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .frame(width: 84, height: 84)
                .padding(.top, 8)
            }
            .padding(36)
            .frame(width: 560)
            .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private static let size = CGSize(width: 560, height: 400)
    private let state = State()
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Card(state: state))
    }

    func show(step: Int, total: Int, title: String, detail: String, left: Int, duration: Int) {
        state.step = step
        state.total = total
        state.title = title
        state.detail = detail
        state.left = left
        state.duration = duration
        guard !panel.isVisible, let frame = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
