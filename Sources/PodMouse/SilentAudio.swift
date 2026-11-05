import AVFoundation

/// Plays silence to the current output. AirPods send motion only to the device they are
/// playing for, and macOS routes stem presses to the app that is actually playing.
final class SilentAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var isConfigured = false
    private var isWanted = false
    private var routeObserver: NSObjectProtocol?

    func start() {
        isWanted = true
        if !isConfigured {
            isConfigured = true
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            routeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.play() }
        }
        play()
    }

    func stop() {
        isWanted = false
        player.stop()
        engine.stop()
    }

    private func play() {
        guard isWanted, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        silence.frameLength = silence.frameCapacity
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if !player.isPlaying {
                player.scheduleBuffer(silence, at: nil, options: .loops)
                player.play()
            }
        } catch {
            NSLog("PodMouse: silent audio failed: \(error.localizedDescription)")
        }
    }
}
