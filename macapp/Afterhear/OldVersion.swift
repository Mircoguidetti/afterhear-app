import Foundation

/// The app used to be called asaid (identifier app.asaid.mac, folder "asaid"). After the rename the Mac
/// saw a new app: the settings, the tester code and the moments stayed with the old one (owner, 03/10).
/// Once, at the first launch of this version, they're brought over; the old copies are left untouched.
/// The account isn't: macOS would ask for the old app's Keychain item, so you simply sign in again.
enum OldVersion {
    private static let oldDomain = "app.asaid.mac"
    private static let oldFolder = "asaid"
    private static let doneKey = "broughtOverFromAsaid"

    static func bringOver() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        // Settings and the tester code: only what this version doesn't have yet (or has empty).
        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in old {
                let current = defaults.object(forKey: key)
                if current == nil || (current as? String)?.isEmpty == true { defaults.set(value, forKey: key) }
            }
        }
        bringOverFiles()
    }

    private static func bringOverFiles() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent(oldFolder, isDirectory: true)
        let new = support.appendingPathComponent("Afterhear", isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) {
            try? fm.copyItem(at: old, to: new)
            return
        }
        // Both exist (this version already ran): moments and known expressions are merged, the rest
        // (clips, models, podcasts) is copied where it's missing.
        mergeList(old.appendingPathComponent("moments.json"), into: new.appendingPathComponent("moments.json"), id: "id")
        mergeStrings(old.appendingPathComponent("known.json"), into: new.appendingPathComponent("known.json"))
        copyMissing(from: old, to: new, skipping: ["moments.json", "known.json"])
    }

    /// Two JSON lists of objects, one entry per id, the new copy wins.
    private static func mergeList(_ old: URL, into new: URL, id: String) {
        guard let oldData = try? Data(contentsOf: old),
              let oldItems = try? JSONSerialization.jsonObject(with: oldData) as? [[String: Any]] else { return }
        let newItems = (try? Data(contentsOf: new)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let have = Set(newItems.compactMap { $0[id] as? String })
        let merged = oldItems.filter { ($0[id] as? String).map { !have.contains($0) } ?? false } + newItems
        if let data = try? JSONSerialization.data(withJSONObject: merged) { try? data.write(to: new, options: .atomic) }
    }

    private static func mergeStrings(_ old: URL, into new: URL) {
        guard let oldData = try? Data(contentsOf: old),
              let oldItems = try? JSONSerialization.jsonObject(with: oldData) as? [String] else { return }
        let newItems = (try? Data(contentsOf: new)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        let merged = Array(Set(oldItems + newItems)).sorted()
        if let data = try? JSONSerialization.data(withJSONObject: merged) { try? data.write(to: new, options: .atomic) }
    }

    private static func copyMissing(from old: URL, to new: URL, skipping: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        for name in names where !skipping.contains(name) {
            let source = old.appendingPathComponent(name), target = new.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isFolder)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: source, to: target)
            } else if isFolder.boolValue {
                copyMissing(from: source, to: target, skipping: [])
            }
        }
    }
}
