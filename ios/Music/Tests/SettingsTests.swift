import XCTest
import UIKit
@testable import Music

@MainActor
final class SettingsTests: XCTestCase {
    private var originalQuality: QobuzStreamQuality!

    override func setUp() {
        super.setUp()
        originalQuality = QobuzPreferences.quality
        QobuzPreferences.quality = .cd
    }

    override func tearDown() {
        QobuzPreferences.quality = originalQuality
        super.tearDown()
    }

    private func settings() -> SettingsViewController {
        let controller = SettingsViewController(items: [], lastFMUsername: nil, appearanceMode: AppearanceMode.allCases[0])
        controller.loadViewIfNeeded()
        return controller
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testQualitySelectionPersistsWithoutRootCallback() throws {
        let controller = settings()
        let control = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UISegmentedControl }.first { $0.accessibilityIdentifier == "settings.qobuzQuality" })
        for quality in [QobuzStreamQuality.mp3, .hiRes192, .hiRes96, .cd] {
            control.selectedSegmentIndex = try XCTUnwrap(QobuzStreamQuality.allCases.firstIndex(of: quality))
            control.sendActions(for: .valueChanged)
            XCTAssertEqual(QobuzPreferences.quality, quality)
        }
    }

    func testSettingsRefreshesQualityWhenReturning() throws {
        let controller = settings()
        QobuzPreferences.quality = .hiRes192
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        let control = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UISegmentedControl }.first { $0.accessibilityIdentifier == "settings.qobuzQuality" })
        XCTAssertEqual(control.selectedSegmentIndex, QobuzStreamQuality.allCases.firstIndex(of: .hiRes192))
    }

    func testGuidanceDescribesRequestedNotGuaranteedOutputQuality() throws {
        let controller = settings()
        let control = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UISegmentedControl }.first { $0.accessibilityIdentifier == "settings.qobuzQuality" })
        for (quality, detail) in [(QobuzStreamQuality.mp3, "320 kbps"), (.cd, "16-bit / 44.1 kHz"), (.hiRes96, "24-bit / 96 kHz"), (.hiRes192, "24-bit / 192 kHz")] {
            control.selectedSegmentIndex = try XCTUnwrap(QobuzStreamQuality.allCases.firstIndex(of: quality))
            control.sendActions(for: .valueChanged)
            let text = descendants(controller.view).compactMap { $0 as? UILabel }.compactMap(\.text).joined(separator: " ")
            XCTAssertTrue(text.contains("Requested quality"))
            XCTAssertTrue(text.contains(detail))
            XCTAssertTrue(text.contains("subscription"))
            XCTAssertTrue(text.contains("output"))
        }
    }

    func testAccountHasReachableDismissAndSignInControls() throws {
        let controller = QobuzAccountViewController()
        controller.loadViewIfNeeded()
        let buttons = descendants(controller.view).compactMap { $0 as? UIButton }
        let close = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "qobuz.account.close" })
        XCTAssertFalse(close.isHidden)
        XCTAssertTrue(close.isEnabled)
        let action = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "qobuz.account.action" })
        XCTAssertFalse(action.isHidden)
    }
}
