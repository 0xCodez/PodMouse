import CoreAudio
import Foundation

/// Reads and changes the Mac's sound output, which decides whether AirPods send motion here.
enum AudioRoute {
    static var currentOutputName: String? {
        defaultOutput.flatMap(name(of:))
    }

    static var isOnHeadphones: Bool {
        currentOutputName.map(looksLikeHeadphones) ?? false
    }

    @discardableResult
    static func switchToHeadphones() -> Bool {
        guard var device = allDevices.first(where: { hasOutput($0) && (name(of: $0).map(looksLikeHeadphones) ?? false) }) else {
            return false
        }
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device) == noErr
    }

    private static func looksLikeHeadphones(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("airpods") || name.localizedCaseInsensitiveContains("beats")
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultOutput: AudioDeviceID? {
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private static var allDevices: [AudioDeviceID] {
        var address = systemAddress(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = systemAddress(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
