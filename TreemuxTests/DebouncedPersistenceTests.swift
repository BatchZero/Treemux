import XCTest
@testable import Treemux

@MainActor
final class DebouncedPersistenceTests: XCTestCase {

    func testDebouncedSaverCoalescesBurstIntoSingleSave() async {
        var saves: [DebouncedSaver.Mode] = []
        let saver = DebouncedSaver(interval: 0.05) { mode in saves.append(mode) }
        for _ in 0..<5 { saver.schedule() }
        XCTAssertTrue(saves.isEmpty, "must not save before interval elapses")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(saves, [.debounced], "burst must coalesce into exactly one save")
    }

    func testFlushCancelsPendingAndSavesSynchronously() async {
        var saves: [DebouncedSaver.Mode] = []
        let saver = DebouncedSaver(interval: 0.05) { mode in saves.append(mode) }
        saver.schedule()
        saver.flush()
        XCTAssertEqual(saves, [.flush], "flush must save immediately")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(saves, [.flush], "cancelled debounce must not fire afterwards")
    }

    func testFlushWithoutPendingStillSaves() {
        var saves: [DebouncedSaver.Mode] = []
        let saver = DebouncedSaver(interval: 0.05) { mode in saves.append(mode) }
        saver.flush()
        XCTAssertEqual(saves, [.flush], "flush is unconditional so exit always writes latest state")
    }

    func testSettingsChangeIsDebouncedThenFlushPersists() {
        let store = WorkspaceStore()
        var draft = store.settings
        draft.terminal.fontSizeOffset = (draft.terminal.fontSizeOffset == 2) ? 3 : 2
        store.updateSettings(draft)
        store.flushPendingPersistence()
        let reloaded = AppSettingsPersistence().load()
        XCTAssertEqual(reloaded.terminal.fontSizeOffset, draft.terminal.fontSizeOffset,
                       "flush must persist the latest in-memory settings")
    }
}
