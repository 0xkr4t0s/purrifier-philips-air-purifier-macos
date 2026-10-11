import Foundation
import PurifierModel

/// Human-readable status output.
enum StatusFormatter {
    static func summary(_ state: PurifierState) -> String {
        var rows: [(String, String)] = []
        let device = state.device
        let title = [device.name, device.model.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")

        rows.append(("Power", state.isOn.map { $0 ? "on" : "off" } ?? "unknown"))
        if state.capabilities.modes.isEmpty == false || state.rawMode != nil {
            var mode = state.mode?.rawValue ?? state.rawMode.map { "unknown (\($0.pythonJSON))" } ?? "unknown"
            if let speed = state.fanSpeed {
                mode += " (fan speed \(speed))"
            }
            rows.append(("Mode", mode))
        }
        if let pm25 = state.pm25 {
            rows.append(("PM2.5", "\(pm25) µg/m³"))
        }
        if let iai = state.allergenIndex {
            rows.append(("Allergen", "\(iai) (IAI)"))
        }
        if let index = state.preferredIndex {
            let text = switch index {
            case .allergenIndex: "allergen index"
            case .pm25: "PM2.5"
            case let .other(value): value.pythonJSON
            }
            rows.append(("Display", text))
        }
        if let remaining = state.filterRemainingHours, let total = state.filterTotalHours {
            // Round down: "100%" should mean a new filter.
            let percent = state.filterRemainingFraction.map { " (\(Int(($0 * 100).rounded(.down)))%)" } ?? ""
            rows.append(("Filter", "\(remaining) / \(total) h\(percent)"))
        }
        if let lock = state.childLock {
            rows.append(("Child lock", lock ? "on" : "off"))
        }
        if let light = state.displayLight {
            rows.append(("Light", "\(light)"))
        }
        if let error = state.errorCode {
            rows.append(("Error", error == 0 ? "none" : "code \(error)"))
        }
        if let rssi = device.rssi {
            rows.append(("Wi-Fi", "\(rssi) dBm"))
        }

        let firmware = [
            state.generation.displayName,
            device.wifiVersion.map { "firmware \($0)" },
            device.softwareVersion.map { "software \($0)" },
        ].compactMap(\.self).joined(separator: ", ")

        let width = rows.map(\.0.count).max() ?? 0
        let body = rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }
        return ([title.isEmpty ? "Purifier" : title, firmware] + body).joined(separator: "\n")
    }

    static func line(_ state: PurifierState) -> String {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        var parts = [time, state.isOn == true ? "on" : "off"]
        if let mode = state.mode {
            parts.append(mode.rawValue)
        }
        if let pm25 = state.pm25 {
            parts.append("PM2.5 \(pm25)")
        }
        if let iai = state.allergenIndex {
            parts.append("IAI \(iai)")
        }
        return parts.joined(separator: "  ")
    }
}
