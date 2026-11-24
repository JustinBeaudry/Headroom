import XCTest
@testable import HeadroomCore

final class UpdateCheckerTests: XCTestCase {
    func testAppVersionSemVerParsingAndComparison() {
        let v1 = AppVersion(parsing: "v0.4.4")
        let v2 = AppVersion(parsing: "0.4.5")
        let v3 = AppVersion(parsing: "v0.10.0")
        let v4 = AppVersion(parsing: "1.0.0-beta.1")

        XCTAssertEqual(v1, AppVersion(major: 0, minor: 4, patch: 4))
        XCTAssertLessThan(v1!, v2!)
        XCTAssertLessThan(v2!, v3!)
        XCTAssertLessThan(v3!, v4!)
        XCTAssertEqual(v2?.tagString, "v0.4.5")
    }

    func testUpdateCheckerDetectsNewReleaseAndParsesAssetsAndNotes() async {
        let mock = MockHTTPClient { _ in
            let body = """
            {
              "tag_name": "v0.4.6",
              "name": "Headroom v0.4.6",
              "body": "## What's New in Headroom v0.4.6\\n\\n- Added in-app release notes\\n- Fixed multi-account filtering\\n",
              "published_at": "2026-11-24T16:00:00Z",
              "html_url": "https://github.com/JustinBeaudry/Headroom/releases/tag/v0.4.6",
              "assets": [
                {
                  "name": "Headroom-v0.4.6-macos-arm64.zip",
                  "browser_download_url": "https://github.com/JustinBeaudry/Headroom/releases/download/v0.4.6/Headroom-v0.4.6-macos-arm64.zip"
                },
                {
                  "name": "Headroom-v0.4.6-macos-arm64.dmg",
                  "browser_download_url": "https://github.com/JustinBeaudry/Headroom/releases/download/v0.4.6/Headroom-v0.4.6-macos-arm64.dmg"
                },
                {
                  "name": "SHA256SUMS.txt",
                  "browser_download_url": "https://github.com/JustinBeaudry/Headroom/releases/download/v0.4.6/SHA256SUMS.txt"
                }
              ]
            }
            """.data(using: .utf8)!
            return HTTPResponse(statusCode: 200, body: body)
        }

        let checker = UpdateChecker(httpClient: mock)
        let result = await checker.checkForUpdates(currentVersion: AppVersion(major: 0, minor: 4, patch: 5))

        guard case .updateAvailable(let current, let release) = result else {
            return XCTFail("Expected .updateAvailable, got \(result)")
        }
        XCTAssertEqual(current, AppVersion(major: 0, minor: 4, patch: 5))
        XCTAssertEqual(release.tagName, "v0.4.6")
        XCTAssertEqual(release.zipAssetName, "Headroom-v0.4.6-macos-arm64.zip")
        XCTAssertNotNil(release.checksumsURL)
        XCTAssertEqual(release.summaryHighlight, "Added in-app release notes")

        // When already on v0.4.6, reports .upToDate
        let upToDate = await checker.checkForUpdates(currentVersion: AppVersion(major: 0, minor: 4, patch: 6))
        guard case .upToDate = upToDate else {
            return XCTFail("Expected .upToDate, got \(upToDate)")
        }
    }

    func testChecksumFileParserHandlesStandardShasumOutput() {
        let sample = """
        9f6db801537d12e02895387abcdef0123456789  Headroom-v0.4.5-macos-arm64.zip
        5339d6a4998a4bcc8f06021abcdef0123456789  headroom-cli-v0.4.5-macos-arm64.tar.gz
        """
        let map = UpdateChecker.parseChecksums(sample)
        XCTAssertEqual(map["Headroom-v0.4.5-macos-arm64.zip"], "9f6db801537d12e02895387abcdef0123456789")
        XCTAssertEqual(map.count, 2)
    }
}
