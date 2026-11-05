import Foundation

struct HeadphoneInfo: Equatable {
    var name: String
    /// 0...100, the lower of the two buds.
    var battery: Int?

    /// macOS has no public battery API for AirPods; System Information reports it.
    static func readConnected(completion: @escaping (HeadphoneInfo?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let info = read()
            DispatchQueue.main.async { completion(info) }
        }
    }

    private static func read() -> HeadphoneInfo? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPBluetoothDataType"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]],
              let connected = sections.first?["device_connected"] as? [[String: [String: Any]]] else { return nil }

        for entry in connected {
            for (name, details) in entry where name.localizedCaseInsensitiveContains("airpods") || name.localizedCaseInsensitiveContains("beats") {
                let levels = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelMain"]
                    .compactMap { details[$0] as? String }
                    .compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
                return HeadphoneInfo(name: name, battery: levels.min())
            }
        }
        return nil
    }
}
