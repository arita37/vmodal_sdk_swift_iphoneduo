import Foundation
import XCTest

#if os(macOS)
final class ShellScriptsTests: XCTestCase {
    private let scripts = [
        "install.sh", "build.sh", "run.sh", "test.sh", "cli.sh", "env.sh", "security_check.sh",
    ]

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @discardableResult
    private func run(_ args: [String], env: [String: String] = [:]) throws -> (Int32, String) {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args
        proc.currentDirectoryURL = root
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        try proc.run()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testScriptsHaveStableCLI() throws {
        for script in scripts {
            let url = root.appendingPathComponent(script)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), script)
            XCTAssertEqual(try run(["bash", "-n", script]).0, 0, script)
            let help = try run(["bash", script, "help"])
            XCTAssertEqual(help.0, 0, script)
            XCTAssertTrue(help.1.contains("Usage"), script)
            XCTAssertNotEqual(try run(["bash", script, "not-a-command"]).0, 0, script)
        }
    }

    func testEnvironmentIsSilentIdempotentAndPreservesExplicitValues() throws {
        let sentinel = "never-print-this-secret"
        let command = "source env.sh; sdk_env_live; sdk_env_live; test \"$VMODAL_API_KEY\" = \"$EXPECT\"; test \"$VMODAL_BASE_URL\" = https://explicit.example"
        let result = try run(["bash", "-c", command], env: [
            "EXPECT": sentinel,
            "VMODAL_API_KEY": sentinel,
            "VMODAL_BASE_URL": "https://explicit.example",
            "TEST_CLIENT_CLERK_USER_API_TOKEN": "fallback",
        ])
        XCTAssertEqual(result.0, 0)
        XCTAssertFalse(result.1.contains(sentinel))
    }

    func testAllOrderAndLiveExclusion() throws {
        let security = try String(contentsOf: root.appendingPathComponent("security_check.sh"))
        XCTAssertTrue(security.contains("sdk_workflow; sdk_toolchain; sdk_version; sdk_license; sdk_routes; sdk_package; sdk_secrets; sdk_forbidden"))
        let tests = try String(contentsOf: root.appendingPathComponent("test.sh"))
        XCTAssertTrue(tests.contains("sdk_test; sdk_security; sdk_package; sdk_sim; sdk_ios"))
        XCTAssertFalse(tests.contains("sdk_ios; sdk_live"))
    }

    func testReleaseSurfaceAndSafetyGuards() throws {
        let manifest = try String(contentsOf: root.appendingPathComponent("Tools/ReleaseManifest/main.swift"))
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"))
        let security = try String(contentsOf: root.appendingPathComponent("security_check.sh"))
        for script in scripts { XCTAssertTrue(manifest.contains("\"\(script)\""), script) }
        XCTAssertTrue(manifest.contains("\"Tools\""))
        XCTAssertTrue(build.contains("Refusing cleanup outside VModalSDK package"))
        XCTAssertTrue(security.contains("push[[:space:]]+--force"))
        XCTAssertTrue(security.contains("--no-verify"))
    }

    func testGitHubActionsReleaseScript() throws {
        let script = root.appendingPathComponent("ga_release.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        XCTAssertEqual(try run(["bash", "-n", "ga_release.sh"]).0, 0)
        XCTAssertEqual(try run(["bash", "ga_release.sh", "help"]).0, 0)
        XCTAssertNotEqual(try run(["bash", "ga_release.sh", "not-a-command"]).0, 0)
        let value = try String(contentsOf: script)
        XCTAssertTrue(value.contains("v-modal/vmodal_sdk_swift_iphoneduo"))
        XCTAssertTrue(value.contains("git push --atomic"))
        XCTAssertFalse(value.contains("push --force"))
        let token = try run(
            ["bash", "ga_release.sh", "ga_public_token"],
            env: ["RELEASE_TOKEN": "never-print-this-release-token"]
        )
        XCTAssertEqual(token.0, 0)
        XCTAssertFalse(token.1.contains("never-print-this-release-token"))
    }

    func testDocumentedCommandsAreExported() throws {
        let readme = root.appendingPathComponent("README.md")
        guard FileManager.default.fileExists(atPath: readme.path) else { return }
        let value = try String(contentsOf: readme)
        let regex = try NSRegularExpression(pattern: #"bash ([a-z_]+\.sh)"#)
        let range = NSRange(value.startIndex..., in: value)
        for match in regex.matches(in: value, range: range) {
            guard let capture = Range(match.range(at: 1), in: value) else { continue }
            let name = String(value[capture])
            XCTAssertTrue(scripts.contains(name), name)
        }
    }
}
#endif
