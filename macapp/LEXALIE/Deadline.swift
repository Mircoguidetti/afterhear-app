import Foundation

/// Waits for `work` at most `seconds`; nil when it takes longer (the work keeps going, unused).
func withDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
