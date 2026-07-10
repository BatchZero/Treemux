import Foundation

/// Trailing-edge debouncer for persistence writes. Repeated `schedule()`
/// calls within `interval` coalesce into one save. `flush()` cancels any
/// pending timer and saves unconditionally — exit paths always write the
/// latest state, ordered after any in-flight background write.
@MainActor
final class DebouncedSaver {
    enum Mode: Equatable {
        /// Fired by the debounce timer; caller should encode + write on a
        /// background queue.
        case debounced
        /// Fired by `flush()`; caller must encode + write synchronously
        /// (the process may be about to exit).
        case flush
    }

    private let interval: TimeInterval
    private let save: @MainActor (Mode) -> Void
    private var pending: DispatchWorkItem?

    var hasPendingSave: Bool { pending != nil }

    init(interval: TimeInterval = 0.25, save: @escaping @MainActor (Mode) -> Void) {
        self.interval = interval
        self.save = save
    }

    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.save(.debounced)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        save(.flush)
    }
}
