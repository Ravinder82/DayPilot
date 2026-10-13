import Foundation

/// A mutex-protected box for a single value.
///
/// Exists so the capture pipeline can read a value owned by main-actor state
/// (`ScreenCaptureEngine`'s suppression flag) without an actor hop on every
/// frame, and without capturing the main actor.
final class ThreadSafeBox<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage = newValue
    }

    /// Reads the current value and writes it back atomically.
    func update(_ transform: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        transform(&storage)
    }
}
