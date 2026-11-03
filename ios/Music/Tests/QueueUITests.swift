import XCTest
import UIKit
@testable import Music

@MainActor
final class QueueUITests: XCTestCase {
    private func find<T: UIView>(_ type: T.Type, in view: UIView, id: String? = nil) -> T? {
        if let match = view as? T, id == nil || view.accessibilityIdentifier == id { return match }
        return view.subviews.compactMap { find(type, in: $0, id: id) }.first
    }

    func testHeaderEditControlMakesPositionalQueueEditingReachableAndSurvivesUpdates() throws {
        let tracks = ["past", "current", "duplicate", "other", "duplicate"].map {
            ScreenTrack(id: $0, title: $0, artist: "Artist", album: "Album", duration: 180)
        }
        let controller = QueueViewController(tracks: tracks, currentIndex: 1)
        var removed: Int?
        var moved: (Int, Int)?
        controller.onRemoveTrack = { removed = $0 }
        controller.onMoveTrack = { moved = ($0, $1) }
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(find(UITableView.self, in: controller.view))
        func editButton() throws -> UIButton {
            try XCTUnwrap(find(UIButton.self, in: controller.view, id: "queue.edit"))
        }
        XCTAssertFalse(table.isEditing)
        XCTAssertEqual(try editButton().title(for: .normal), "Edit")
        XCTAssertEqual(try editButton().accessibilityLabel, "Edit queue")
        try editButton().sendActions(for: .touchUpInside)
        XCTAssertTrue(table.isEditing)
        XCTAssertEqual(try editButton().title(for: .normal), "Done")
        XCTAssertTrue(controller.tableView(table, canMoveRowAt: IndexPath(row: 2, section: 0)))
        controller.tableView(table, moveRowAt: IndexPath(row: 2, section: 0), to: IndexPath(row: 0, section: 0))
        XCTAssertEqual(moved?.0, 4)
        XCTAssertEqual(moved?.1, 2)
        controller.tableView(table, commit: .delete, forRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(removed, 3)
        controller.update(tracks: Array(tracks.dropLast()), currentIndex: 1)
        XCTAssertTrue(table.isEditing)
        XCTAssertEqual(try editButton().title(for: .normal), "Done")
        var metadata = Array(tracks.dropLast())
        metadata[1] = ScreenTrack(id: "current", title: "Updated", artist: "Artist", album: "Album")
        controller.update(tracks: metadata, currentIndex: 1)
        XCTAssertEqual(try editButton().title(for: .normal), "Done")
        try editButton().sendActions(for: .touchUpInside)
        XCTAssertFalse(table.isEditing)
        XCTAssertEqual(try editButton().title(for: .normal), "Edit")
        controller.setQueueEditing(true)
        controller.update(tracks: [], currentIndex: 0)
        XCTAssertEqual(try editButton().title(for: .normal), "Done")
        XCTAssertTrue(try editButton().isEnabled, "Done must remain reachable after clearing Up Next")
        try editButton().sendActions(for: .touchUpInside)
        XCTAssertFalse(table.isEditing)
    }
}
