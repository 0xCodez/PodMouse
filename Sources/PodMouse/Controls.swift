import SwiftUI

// Every control here is pure SwiftUI: AppKit-backed ones come out blank in `ImageRenderer` snapshots.

extension Animation {
    /// The app's spring, or a plain fade with Reduce Motion on.
    static var pod: Animation { Theme.reduceMotion ? .easeOut(duration: 0.18) : Theme.spring }
    /// For something that travels, which with Reduce Motion on jumps instead.
    static var podTravel: Animation? { Theme.reduceMotion ? nil : Theme.snap }
    static let podFade = Animation.easeOut(duration: 0.16)
}

extension AnyTransition {
    /// For rows joining the layout.
    static var podRow: AnyTransition {
        Theme.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6))
    }
    /// For a card that arrives with some weight.
    static var podCard: AnyTransition {
        Theme.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }
}

private extension Adaptive {
    /// The moving pill of the switcher, which needs more lift than `.raised` gives in the dark.
    static let pill = Adaptive(light: .white, dark: Color(white: 0.24))
    /// A switch thumb on a filled track, which inverts with the ink.
    static let thumbOnInk = Adaptive(light: .white, dark: Color(white: 0.1))
}

private let auroraSweep = LinearGradient(colors: Theme.aurora, startPoint: .leading, endPoint: .trailing)
private let knobInk = Color(red: 0.07, green: 0.07, blue: 0.1)

/// Hit testing and nothing else, so a custom control isn't drawn over by a system button style.
private struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private extension View {
    func toggleTraits(isOn: Bool) -> some View {
        accessibilityAddTraits(.isToggle)
            .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: Toggles

private struct SwitchThumb: View {
    let isOn: Bool
    let fill: AnyShapeStyle
    let travel: CGFloat
    let side: CGFloat

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .offset(x: isOn ? travel / 2 : -travel / 2)
            .animation(.podTravel, value: isOn)
    }
}

/// A settings row: the label, then a small ink switch.
struct PodToggleStyle: ToggleStyle {
    private static let size = CGSize(width: 32, height: 19)

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                    .font(.pod(12.5))
                    .foregroundStyle(.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Capsule().fill(.hairline)
                    Capsule().fill(.ink).opacity(isOn ? 1 : 0).animation(.podFade, value: isOn)
                    SwitchThumb(
                        isOn: isOn,
                        fill: isOn ? AnyShapeStyle(Adaptive.thumbOnInk) : AnyShapeStyle(Color.white),
                        travel: Self.size.width - Self.size.height,
                        side: Self.size.height - 4
                    )
                }
                .frame(width: Self.size.width, height: Self.size.height)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BareButtonStyle())
        .toggleTraits(isOn: isOn)
    }
}

/// The master switch, the one control that always carries the light. Hides its label.
struct PowerToggleStyle: ToggleStyle {
    private static let size = CGSize(width: 46, height: 28)

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            ZStack {
                Capsule().fill(auroraSweep).blur(radius: 9).opacity(isOn ? 0.55 : 0)
                Capsule().fill(.hairline)
                Capsule().fill(auroraSweep).opacity(isOn ? 1 : 0)
                ZStack {
                    SwitchThumb(isOn: isOn, fill: AnyShapeStyle(Color.white), travel: Self.size.width - Self.size.height, side: Self.size.height - 5)
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(knobInk.opacity(isOn ? 0.85 : 0.4))
                        .offset(x: isOn ? 9 : -9)
                        .animation(.podTravel, value: isOn)
                }
            }
            .animation(.podFade, value: isOn)
            .frame(width: Self.size.width, height: Self.size.height)
            .contentShape(Capsule())
        }
        .buttonStyle(BareButtonStyle())
        .accessibilityLabel { _ in configuration.label }
        .toggleTraits(isOn: isOn)
    }
}

struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.pod(11.5, .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.surface) : AnyShapeStyle(.ink2))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background {
                    ZStack {
                        Capsule().fill(.hairline)
                        Capsule().fill(.ink).opacity(isOn ? 1 : 0)
                    }
                }
                .contentShape(Capsule())
                .animation(.podFade, value: isOn)
        }
        .buttonStyle(BareButtonStyle())
        .toggleTraits(isOn: isOn)
    }
}

// MARK: Buttons

/// Text that comes forward under the pointer.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.pod(11.5))
                .foregroundStyle(hovering ? .ink : .ink2)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.podFade, value: hovering)
        }
    }
}

struct InkPillButtonStyle: ButtonStyle {
    var font = Font.pod(11.5, .semibold)
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.surface)
            .padding(.horizontal, height * 0.6)
            .frame(height: height)
            .background(.ink, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !Theme.reduceMotion ? 0.97 : 1)
            .animation(.podTravel, value: configuration.isPressed)
    }
}

/// The light, loose behind a control.
struct AuroraGlow: View {
    var body: some View {
        Capsule().fill(auroraSweep).blur(radius: 20)
    }
}

// MARK: Switcher

/// A pill that slides between options.
struct PodSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.pod) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.pod(12.5, .semibold))
                        .foregroundStyle(selected ? .ink : .ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if selected {
                                // With Reduce Motion each pill keeps its own id, so they fade instead of sliding.
                                Capsule()
                                    .fill(Adaptive.pill)
                                    .shadow(color: .black.opacity(0.12), radius: 5, y: 1.5)
                                    .matchedGeometryEffect(id: Theme.reduceMotion ? AnyHashable(option.value) : AnyHashable("pill"), in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(BareButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.hairline, in: Capsule())
    }
}

// MARK: Slider

/// Where values land on a slider's track. Knob and fill share it, so a meter under the
/// knob crosses it at exactly the value the knob stands for.
struct TrackScale {
    let range: ClosedRange<Double>
    let width: CGFloat
    /// How far the knob's centre stays from the ends.
    let inset: CGFloat

    private var usable: CGFloat { max(width - inset * 2, 1) }

    func x(_ value: Double) -> CGFloat {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return inset + usable * CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    func value(atX x: CGFloat) -> Double {
        let unit = min(max(Double((x - inset) / usable), 0), 1)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

/// A thin track and a white knob that grows into a tag with the value while it's dragged.
/// `fill` draws on the track, in the track's frame.
struct PodSlider<Fill: View>: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: (Double) -> String
    @ViewBuilder let fill: (TrackScale) -> Fill

    @State private var dragging = false

    private static var trackHeight: CGFloat { 4 }
    private static var knobSide: CGFloat { 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.pod(12.5))
                .foregroundStyle(.ink)
            GeometryReader { box in
                let scale = TrackScale(range: range, width: box.size.width, inset: Self.knobSide / 2)
                ZStack(alignment: .leading) {
                    Capsule().fill(.hairline).frame(height: Self.trackHeight)
                    fill(scale).frame(height: Self.trackHeight)
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    knob.position(x: scale.x(value), y: box.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragging = true
                            value = scale.value(atX: drag.location.x)
                        }
                        .onEnded { _ in dragging = false }
                )
            }
            .frame(height: 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }

    private var knob: some View {
        Capsule()
            .fill(.white)
            .shadow(color: .black.opacity(dragging ? 0.26 : 0.2), radius: dragging ? 7 : 3.5, y: dragging ? 3 : 1.5)
            .overlay { Capsule().strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
            .frame(width: dragging ? 42 : Self.knobSide, height: dragging ? 24 : Self.knobSide)
            .overlay {
                Text(text(value))
                    .font(.pod(11, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(knobInk)
                    .fixedSize()
                    .opacity(dragging ? 1 : 0)
            }
            .animation(.podTravel, value: dragging)
    }
}

extension PodSlider where Fill == AuroraFill {
    /// The usual slider, lit from the start of the track up to the knob.
    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, text: @escaping (Double) -> String) {
        self.init(title: title, value: value, range: range, text: text) { scale in
            AuroraFill(end: scale.x(value.wrappedValue))
        }
    }
}

/// The light's colours laid across the whole track and shown up to `end`,
/// so a colour stays put and the knob uncovers it.
struct AuroraFill: View {
    let end: CGFloat

    var body: some View {
        Capsule()
            .fill(auroraSweep)
            .mask(alignment: .leading) { Rectangle().frame(width: end) }
    }
}

// MARK: Keycaps

/// A shortcut, one small key to a character.
struct Keycaps: View {
    let keys: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(String(key))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.ink2)
                    .frame(width: 18, height: 18)
                    .background(.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.hairline, lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys)
    }
}
