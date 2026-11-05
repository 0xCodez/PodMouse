import AppKit
import SwiftUI

/// What the light is doing, from the app's live state.
enum AuraMood: Equatable {
    case off, searching, connected, calibrating, paused

    init(isOn: Bool, isPaused: Bool, isCalibrating: Bool, isReceivingMotion: Bool) {
        if !isOn { self = .off }
        else if isCalibrating { self = .calibrating }
        else if isPaused { self = .paused }
        else { self = isReceivingMotion ? .connected : .searching }
    }
}

/// A one-off flash of the light.
enum AuraPulse {
    case tap, rightClick, step, success
}

/// The single light the whole app shares. Every call is cheap and safe from any thread,
/// because the pointer path makes them.
final class AuraLight {
    func set(mood: AuraMood) {}
    func pulse(_ pulse: AuraPulse) {}
    /// Pushes the light toward where the case is aimed, each axis in -1...1.
    func lean(x: Double, y: Double) {}
    /// Fills the HUD's edge with light, 0...1. Nil turns the arc off.
    func setProgress(_ progress: Double?) {}
}

/// Where one view draws the light. All in points, origin at the top left.
struct AuraStage: Equatable {
    /// The black notch body with its top edge on the view's top edge, drawn by the renderer so its
    /// spring and its glow stay in step. Nil for no body, as in the menu.
    var notch: CGSize?
    var notchRadius: CGFloat = 24
    /// The soft blob behind the case, in unit coordinates of the view.
    var blobCenter = CGPoint(x: 0.5, y: 0.5)
    var blobRadius: CGFloat = 110
    /// The strength of the blob, 0...1.
    var blobStrength = 1.0
    /// True over black or the desktop: the light adds. False over the light surface: it tints.
    var onDark = true
}

extension EnvironmentValues {
    /// True in `--snapshot`, where Metal and SceneKit views are replaced by rendered stills.
    @Entry var stillRendering = false
}

/// The light as a view. It renders on its own thread and only while it's on screen.
struct AuraView: View {
    let light: AuraLight
    var stage = AuraStage()

    var body: some View { Color.clear }
}
