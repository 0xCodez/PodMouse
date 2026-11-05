import MediaPlayer

/// AirPods stem presses reach whichever app macOS considers Now Playing, as media commands:
/// one press toggles playback, two skip forward, three skip back.
final class StemControls {
    enum Press {
        case single, double, triple
    }

    var onPress: ((Press) -> Void)?

    private var targets: [(MPRemoteCommand, Any)] = []
    private var lastSingle: TimeInterval = 0

    /// macOS can send pause and play for one press.
    private static let debounce: TimeInterval = 0.3

    func start() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        add(center.togglePlayPauseCommand, .single)
        add(center.playCommand, .single)
        add(center.pauseCommand, .single)
        add(center.nextTrackCommand, .double)
        add(center.previousTrackCommand, .triple)
        claimNowPlaying()
    }

    func stop() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func add(_ command: MPRemoteCommand, _ press: Press) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.handle(press) }
            return .success
        }
        targets.append((command, target))
    }

    private func handle(_ press: Press) {
        if press == .single {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSingle > Self.debounce else { return }
            lastSingle = now
        }
        claimNowPlaying()
        onPress?(press)
    }

    private func claimNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "PodMouse",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        center.playbackState = .playing
    }
}
