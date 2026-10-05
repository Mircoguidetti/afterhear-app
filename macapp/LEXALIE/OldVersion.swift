import Foundation

/// The app was called asaid (app.asaid.mac, folder "asaid") until 03/10 and Afterhear (app.afterhear.mac,
/// folder "Afterhear") until 05/10: each rename makes the Mac see a new app, and the settings, the tester
/// code, the moments and the downloaded models stayed with the old one (owner, 03/10 and 05/10).
/// Once, at the first launch of this version, they're brought over, the most recent name first.
/// The account isn't: macOS would ask for the old app's Keychain item, so you simply sign in again.
enum OldVersion {
    private struct Old { let domain: String; let folder: String; let models: String?; let doneKey: String }
    private static let olds = [
        Old(domain: "app.afterhear.mac", folder: "Afterhear", models: "app.afterhear.mac", doneKey: "broughtOverFromAfterhear"),
        Old(domain: "app.asaid.mac", folder: "asaid", models: nil, doneKey: "broughtOverFromAsaid"),
    ]
    static let folder = "LEXALIE"

    static func bringOver() {
        let defaults = UserDefaults.standard
        for old in olds where !defaults.bool(forKey: old.doneKey) {
            defaults.set(true, forKey: old.doneKey)
            // Settings and the tester code: only what this version doesn't have yet (or has empty).
            if let values = defaults.persistentDomain(forName: old.domain) {
                for (key, value) in values {
                    let current = defaults.object(forKey: key)
                    if current == nil || (current as? String)?.isEmpty == true { defaults.set(value, forKey: key) }
                }
            }
            bringOverFiles(from: old.folder, to: folder)
            if let models = old.models { bringOverFiles(from: models, to: "app.lexalie.mac") }
        }
    }

    private static func bringOverFiles(from oldName: String, to newName: String) {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent(oldName, isDirectory: true)
        let new = support.appendingPathComponent(newName, isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) {
            // Moved, not copied: the speech models alone are hundreds of megabytes.
            if (try? fm.moveItem(at: old, to: new)) == nil { try? fm.copyItem(at: old, to: new) }
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
