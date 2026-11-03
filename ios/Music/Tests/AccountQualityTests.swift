import XCTest
import UIKit
@testable import Music

@MainActor
final class AccountQualityTests: XCTestCase {
    func testAccountDecodesObservedFieldsAndUnknownSubscription() throws {
        let data = Data(#"{"user":{"id":"42","email":"listener@example.invalid","credential":{"parameters":{"shortLabel":"Studio","losslessStreaming":true}},"subscription":{"offer":"Studio","periodicity":"annual"}},"ignored":true}"#.utf8)
        let account = try JSONDecoder().decode(QobuzAccountResponse.self, from: data)
        XCTAssertEqual(account.user.id, "42")
        XCTAssertTrue(account.displaySummary.contains("Plan: Studio"))
        XCTAssertTrue(account.displaySummary.contains("Billing period: annual"))
        XCTAssertTrue(account.displaySummary.contains("Lossless streaming entitlement: Yes"))
        let missing = try JSONDecoder().decode(QobuzAccountResponse.self, from: Data(#"{"user":{"id":43,"subscription":null,"credential":null}}"#.utf8))
        XCTAssertTrue(missing.displaySummary.contains("Plan information unavailable"))
        XCTAssertFalse(missing.displaySummary.contains("inactive"))
        let malformed = try JSONDecoder().decode(QobuzAccountResponse.self, from: Data(#"{"user":{"id":44,"credential":{"parameters":{"shortLabel":"Studio","losslessStreaming":"unknown"}},"subscription":{"offer":"Studio","periodicity":123}}}"#.utf8))
        XCTAssertTrue(malformed.displaySummary.contains("Plan: Studio"))
        XCTAssertTrue(malformed.displaySummary.contains("Subscription offer: Studio"))
        XCTAssertFalse(malformed.displaySummary.contains("Lossless streaming entitlement:"))
        XCTAssertThrowsError(try JSONDecoder().decode(QobuzAccountResponse.self, from: Data(#"{"error":"expired"}"#.utf8)))
    }

    func testAccountRequestReadsAuthenticatedSessionAndRejectsOtherUser() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountQualityURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); AccountQualityURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-session-only", userID: 42), session: session, catalogAppID: "test-app")
        for id in [42, 99] {
            let done = expectation(description: "account response")
            AccountQualityURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/api.json/0.2/user/login")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-User-Auth-Token"), "test-session-only")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Id"), "test-app")
                XCTAssertNil(request.url?.query)
                return (200, Data("{\"user\":{\"id\":\(id)}}".utf8))
            }
            client.account { result in
                switch result {
                case .success(let account): XCTAssertEqual(id, 42); XCTAssertEqual(account.user.id, "42")
                case .failure: XCTAssertEqual(id, 99)
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
        }
    }

    func testSettingsReportsMeasuredAudioPathAlongsideRequestedQuality() {
        let controller = SettingsViewController(items: [], lastFMUsername: nil, appearanceMode: AppearanceMode.allCases[0])
        controller.loadViewIfNeeded()
        func labels(_ view: UIView) -> [UILabel] {
            (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels)
        }
        let text = labels(controller.view).compactMap(\.text).joined(separator: " ")
        // The audio-path report states the measured source, not an implied session.
        XCTAssertTrue(text.contains("Source:"))
        XCTAssertTrue(text.contains("EQ:"))
        // Bit depth is reported, never claimed as controllable.
        XCTAssertTrue(text.contains("Output bit depth is chosen by iOS"))
    }
}

private final class AccountQualityURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (status, data) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
