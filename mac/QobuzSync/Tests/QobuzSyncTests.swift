import XCTest
@testable import QobuzSync

final class QobuzSyncTests: XCTestCase {
    func testLastFMEligibilityUsesHalfOrFourMinutes() {
        XCTAssertFalse(event(duration: 300, listened: 149).isLastFMEligible)
        XCTAssertTrue(event(duration: 300, listened: 150).isLastFMEligible)
        XCTAssertFalse(event(duration: 900, listened: 239).isLastFMEligible)
        XCTAssertTrue(event(duration: 900, listened: 240).isLastFMEligible)
        XCTAssertFalse(event(duration: 30, listened: 30).isLastFMEligible)
        XCTAssertTrue(event(duration: 31, listened: 15.5).isLastFMEligible)
    }

    func testSignatureIsStableAndExcludesFormat() {
        XCTAssertEqual(
            LastFMClient.signature(
                parameters: ["api_key": "key", "method": "auth.getToken", "format": "json"],
                sharedSecret: "secret"
            ),
            "b4705499705a550b07ca058a15bde9b0"
        )
        XCTAssertEqual(
            LastFMClient.signature(
                parameters: [
                    "api_key": "key",
                    "method": "auth.getSession",
                    "token": "token"
                ],
                sharedSecret: "secret"
            ),
            "9ac306496295a8866c4a8673395540eb"
        )
    }

    func testLastFMAuthorizationPendingIsRecognized() {
        XCTAssertTrue(LastFMError.api(code: 14, message: "Unauthorized Token").isAuthorizationPending)
        XCTAssertFalse(LastFMError.api(code: 9, message: "Invalid session key").isAuthorizationPending)
        XCTAssertTrue(LastFMError.api(code: 13, message: "Invalid method signature supplied").isInvalidSignature)
        XCTAssertFalse(LastFMError.api(code: 14, message: "Unauthorized Token").isInvalidSignature)
    }

    func testLastFMCredentialShapeValidation() {
        XCTAssertTrue(LastFMClient.isValidCredentialValue("0123456789abcdef0123456789ABCDEF"))
        XCTAssertFalse(LastFMClient.isValidCredentialValue("0123456789abcdef0123456789abcde"))
        XCTAssertFalse(LastFMClient.isValidCredentialValue("0123456789abcdef0123456789abcdeg"))
    }

    func testLastFMReadsJSONErrorFromHTTP403() {
        let data = Data(#"{"error":14,"message":"Unauthorized Token"}"#.utf8)
        XCTAssertThrowsError(try LastFMClient.decodeResponse(data: data, httpStatus: 403)) { error in
            guard let lastFMError = error as? LastFMError else {
                return XCTFail("Expected LastFMError, got \(error)")
            }
            XCTAssertTrue(lastFMError.isAuthorizationPending)
            XCTAssertEqual(lastFMError.localizedDescription, "Last.fm error 14: Unauthorized Token")
        }
    }

    func testAFCInfoOutputIsMatchedToRequestedFiles() {
        let output = "\u{001B}[0;30m\u{001B}[47mafc:\u{001B}[m\u{001B}[1;33m\u{001B}[44m/\u{001B}[m > {\n"
            + "  \"st_size\": 74889,\n  \"st_ifmt\": \"S_IFREG\"\n}\n"
            + "\u{001B}[0;30m\u{001B}[47mafc:\u{001B}[m\u{001B}[1;33m\u{001B}[44m/\u{001B}[m > "
            + "Error: Failed to get file info: Not found (8)\n"
            + "\u{001B}[0;30m\u{001B}[47mafc:\u{001B}[m\u{001B}[1;33m\u{001B}[44m/\u{001B}[m > "
        XCTAssertEqual(
            USBDeviceService.parseRemoteFileSizes(
                output,
                relativePaths: ["Album/cover.jpg", "Album/missing.flac"]
            ),
            ["Album/cover.jpg": 74_889]
        )
    }

    private func event(duration: TimeInterval, listened: TimeInterval) -> PlaybackEvent {
        PlaybackEvent(
            schemaVersion: 1,
            id: UUID().uuidString,
            trackID: "track",
            sourceRelativePath: "Album/Track.flac",
            title: "Track",
            artist: "Artist",
            album: "Album",
            albumArtist: "Artist",
            trackNumber: 1,
            startedAt: Date(),
            endedAt: Date(),
            listenedSeconds: listened,
            trackDuration: duration,
            completed: false,
            endReason: .skipped
        )
    }
}
