import AppKit
import CoreMotion
import PodMouseCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            header
            Picker("", selection: $model.prefs.mode) {
                Text(L("Case in hand", "Кейс в руке")).tag(ControlMode.hand)
                Text(L("In your ears", "В ушах")).tag(ControlMode.head)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let problem {
                ProblemRow(problem: problem)
            }

            VStack(spacing: 12) {
                LabeledSlider(title: L("Pointer speed", "Скорость курсора"), value: $model.prefs.sensitivity, range: 0.4...2.5)
                if model.prefs.mode == .hand {
                    TapSlider(threshold: $model.prefs.tapThreshold, jolt: model.lastJolt)
                }
                Divider().opacity(0.5)
                HStack {
                    Text(L("Click by resting on buttons", "Клик при задержке на кнопке"))
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: $model.prefs.dwellEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                HStack {
                    Text(L("Reverse direction", "Обратное направление"))
                        .font(.system(size: 12))
                    Spacer()
                    Toggle(L("Horizontal", "Гор."), isOn: $model.prefs.invertX)
                        .toggleStyle(.button)
                        .controlSize(.small)
                    Toggle(L("Vertical", "Верт."), isOn: $model.prefs.invertY)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
                if model.prefs.mode == .hand {
                    HStack {
                        Text(L("Drag with a left twist", "Перетаскивание поворотом влево"))
                            .font(.system(size: 12))
                        Spacer()
                        Toggle("", isOn: $model.prefs.twistDrags)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }
                }
            }
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            GestureList(mode: model.prefs.mode, twistDrags: model.prefs.twistDrags)

            HStack {
                Button(model.needsCalibration ? L("Set up…", "Настроить…") : L("Recalibrate", "Калибровка")) {
                    model.startCalibration()
                }
                Spacer()
                Button(L("Quit", "Выйти")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var header: some View {
        VStack(spacing: 4) {
            AirPodsView(airpods: model.airpods)
                .frame(height: 150)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PodMouse").font(.system(size: 14, weight: .semibold))
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private var statusText: String {
        if !model.isOn { return L("Off", "Выключен") }
        if model.isCalibrating { return L("Calibrating", "Калибровка") }
        if model.isPaused { return L("Paused", "Пауза") }
        if model.isReceivingMotion { return model.headphones?.name ?? L("Connected", "Подключены") }
        return L("Waiting for AirPods", "Ждём AirPods")
    }

    /// Only the first thing that's wrong: each fix can change what comes next.
    private var problem: Problem? {
        if !model.hasAccessibility {
            return Problem(
                text: L("PodMouse needs Accessibility to move the pointer.", "PodMouse нужен доступ к Универсальному доступу, чтобы двигать курсор."),
                action: L("Open Settings", "Открыть настройки"),
                perform: model.openAccessibilitySettings
            )
        }
        if model.motionAuthorization == .denied || model.motionAuthorization == .restricted {
            return Problem(
                text: L("Motion access is off for PodMouse in Privacy & Security.", "Доступ к движению отключён в разделе «Конфиденциальность и безопасность»."),
                action: nil,
                perform: nil
            )
        }
        guard model.isOn, !model.isReceivingMotion else { return nil }
        if model.prefs.mode == .hand {
            return Problem(
                text: L("No motion yet. Open the case lid and turn off Automatic Ear Detection in your AirPods settings.", "Движения пока нет. Откройте крышку кейса и выключите «Автоматическое обнаружение уха» в настройках AirPods."),
                action: L("Open Bluetooth Settings", "Открыть настройки Bluetooth"),
                perform: model.openBluetoothSettings
            )
        }
        if !model.isOnHeadphones {
            return Problem(
                text: L("AirPods only send motion while they're the Mac's sound output.", "AirPods передают движение, только когда выбраны как выход звука на Mac."),
                action: L("Switch sound to AirPods", "Переключить звук на AirPods"),
                perform: model.switchSoundToHeadphones
            )
        }
        return Problem(text: L("No motion yet. Wear both AirPods.", "Движения пока нет. Наденьте оба наушника."), action: nil, perform: nil)
    }
}

private struct Problem {
    let text: String
    let action: String?
    let perform: (() -> Void)?
}

private struct ProblemRow: View {
    let problem: Problem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(problem.text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            if let action = problem.action, let perform = problem.perform {
                Button(action, action: perform)
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12))
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

/// Stronger taps needed to the right. The bar shows the last jolt, so the threshold can be set by eye.
private struct TapSlider: View {
    @Binding var threshold: Double
    let jolt: Double

    private static let range = 0.2...1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Tap strength", "Сила тапа")).font(.system(size: 12))
            Slider(value: $threshold, in: Self.range).controlSize(.small)
            GeometryReader { bar in
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(jolt > threshold ? Color.accentColor : Color.secondary)
                    .frame(width: bar.size.width * min(jolt / Self.range.upperBound, 1))
            }
            .frame(height: 3)
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
                (L("Hold still, tap the case", "Замереть и тапнуть"), L("Click", "Клик")),
                (L("Twist right and back", "Поворот вправо и обратно"), L("Right click", "Правый клик")),
            ] + (twistDrags ? [(L("Twist left and back", "Поворот влево и обратно"), L("Drag", "Перетаскивание"))] : []) + [
                ("⌃⌥T", L("Pause", "Пауза")),
            ]
        case .head:
            return [
                (L("Nod or press stem", "Кивок или нажатие"), L("Click", "Клик")),
                (L("Press twice", "Двойное нажатие"), L("Right click", "Правый клик")),
                (L("Shake your head", "Покачать головой"), L("Pause", "Пауза")),
                ("⌃⌥C", L("Center pointer", "Курсор в центр")),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1)
                }
            }
        }
        .font(.system(size: 11))
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AirPodsView(airpods: model.airpods)
                .frame(height: 230)
                .padding(.top, 16)
            Text("PodMouse")
                .font(.system(size: 28, weight: .semibold))
                .padding(.top, 16)
            Text(L("Your AirPods case is now a mouse.", "Кейс AirPods теперь мышь."))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 16) {
                WelcomeRow(symbol: "hand.point.up.left", title: L("Hold it like a laser pointer", "Держите как лазерную указку"), detail: L("Rest your elbow, move only your wrist, in short smooth moves.", "Локоть на опоре, двигается только кисть, короткими плавными движениями."))
                WelcomeRow(symbol: "accessibility", title: L("Allow Accessibility", "Разрешите Универсальный доступ"), detail: L("To move the pointer and click for you.", "Чтобы двигать курсор и нажимать за вас."))
                WelcomeRow(symbol: "gyroscope", title: L("Allow Motion", "Разрешите доступ к движению"), detail: L("Processed on your Mac, never sent anywhere.", "Данные остаются на вашем Mac."))
                WelcomeRow(symbol: "ear.badge.waveform", title: L("Turn off Automatic Ear Detection", "Выключите обнаружение уха"), detail: L("In AirPods settings, so motion keeps flowing.", "В настройках AirPods, иначе движение прервётся."))
                WelcomeRow(symbol: "airpods.gen4", title: L("Keep the lid open", "Держите крышку открытой"), detail: L("A few millimetres is enough. Snapping it shut disconnects them.", "Хватит щели в пару миллиметров. Если защёлкнуть, AirPods отключатся."))
            }
            .padding(.top, 26)
            .padding(.horizontal, 44)

            Button {
                onDone()
                model.startCalibration()
            } label: {
                Text(L("Get Started", "Начать"))
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 180, height: 26)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .clipShape(Capsule())
            .padding(.top, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 440)
        .background(.windowBackground)
    }
}

private struct WelcomeRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
