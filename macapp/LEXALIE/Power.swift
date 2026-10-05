import Foundation
import IOKit.ps

/// The Mac's battery (decided 01/10): below 20% and not charging, LEXALIE stops transcribing
/// as it listens. It keeps the sound of what you mark and asks "transcribe now?"; otherwise
/// it does it as soon as the charger is back.
enum Power {
    static let lowPercent = 20

    /// Battery level and charger, or nil on a Mac without a battery.
    static func state() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onCharger = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (current * 100 / max, onCharger)
        }
        return nil
    }

    static func isLow(percent: Int, charging: Bool) -> Bool {
        !charging && percent < lowPercent
    }

    static var isLow: Bool {
        guard let s = state() else { return false }
        return isLow(percent: s.percent, charging: s.charging)
    }
}

/// A mark kept as sound only, waiting to be transcribed (battery low).
struct PendingMark: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var clipFile: String
    var tapAt: Double
    var trigger: String
    var context: String?
    var show: String?
    var call: String?
    var callTitle: String?
    var with: String?

    private static let key = "pendingMarks"

    static var all: [PendingMark] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingMark].self, from: data)) ?? []
    }

    static func save(_ marks: [PendingMark]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(marks), forKey: key)
    }
}
