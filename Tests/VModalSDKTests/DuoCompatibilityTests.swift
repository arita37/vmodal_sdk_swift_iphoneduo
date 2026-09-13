import Foundation
import XCTest

final class XcodeCompatibilityTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testXcode26ToolchainAndStarterProject() throws {
        let xcode = try String(contentsOf: root.appendingPathComponent(".xcode-version"))
        let project = try String(contentsOf: root.appendingPathComponent("Examples/StarterIOS/StarterIOS.xcodeproj/project.pbxproj"))
        XCTAssertEqual(xcode.trimmingCharacters(in: .whitespacesAndNewlines), "26.6")
        XCTAssertTrue(project.contains("LastUpgradeCheck = 2660"))
        XCTAssertTrue(project.contains("CreatedOnToolsVersion = 26.6"))
    }

    func testStarterUsesCompatibleFlexibleLayout() throws {
        let app = try String(contentsOf: root.appendingPathComponent("Examples/StarterIOS/StarterIOS/StarterIOSApp.swift"))
        let session = try String(contentsOf: root.appendingPathComponent("Examples/StarterIOS/StarterIOS/AppSession.swift"))
        let view = try String(contentsOf: root.appendingPathComponent("Examples/StarterIOS/StarterIOS/ContentView.swift"))
        XCTAssertTrue(app.contains("@StateObject private var session"))
        XCTAssertTrue(session.contains("private var upload: UploadTask"))
        XCTAssertTrue(session.contains("guard upload == nil"))
        XCTAssertTrue(view.contains("NavigationSplitView"))
        XCTAssertTrue(view.contains("frame(maxWidth:"))
        XCTAssertFalse(view.contains("UIScreen.main.bounds"))
    }
}

/* FUTURE_IPHONE_DUO_XCODE_27_1
final class DuoCompatibilityTests: XCTestCase {
    func testDuoMatrixCoversRequiredTransitions() throws {
        let matrix = try String(contentsOf: root.appendingPathComponent("docs/iphone_duo_acceptance.md"))
        for term in ["folded", "unfolded", "Split View", "safe areas", "Two windows", "no second"] {
            XCTAssertTrue(matrix.contains(term), term)
        }
    }
}
*/
