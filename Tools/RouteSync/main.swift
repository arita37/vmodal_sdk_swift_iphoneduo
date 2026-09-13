import Foundation
import VModalSDK

func routeFixture(_ path: String) throws -> [RouteSpec] {
    try JSONDecoder().decode([RouteSpec].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        .sorted { $0.name < $1.name }
}

func swiftString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

func generatedSource(_ specs: [RouteSpec]) -> String {
    let prefix = Data("/api/external/v1".utf8).base64EncodedString()
    let usersPrefix = Data("/api/v1".utf8).base64EncodedString()
    var rows = [
        "// GENERATED CODE - DO NOT MODIFY BY HAND.",
        "// Obfuscation is anti-grep only, not security.",
        "",
        "import Foundation",
        "",
        "private let encodedRouteValues: [String: String] = [",
        "    \"prefix\": \"\(prefix)\",",
        "    \"usersApiPrefix\": \"\(usersPrefix)\",",
    ]
    for spec in specs {
        rows.append("    \"\(swiftString(spec.name))\": \"\(Data(spec.path.utf8).base64EncodedString())\",")
    }
    rows += [
        "]", "",
        "func routeValue(_ key: String) -> String {",
        "    String(decoding: Data(base64Encoded: encodedRouteValues[key]!)!, as: UTF8.self)",
        "}", "", "public extension Routes {", "    static let specs: [RouteSpec] = [",
    ]
    for spec in specs {
        rows.append("        .init(name: \"\(swiftString(spec.name))\", method: \"\(swiftString(spec.method))\", path: routeValue(\"\(swiftString(spec.name))\"), category: .\(spec.category.rawValue), source: \"\(swiftString(spec.source))\"),")
    }
    rows += ["    ]", "}", ""]
    return rows.joined(separator: "\n")
}

let args = Array(ProcessInfo.processInfo.arguments.dropFirst())
do {
    guard args.count == 3, ["generate", "check"].contains(args[0]) else {
        throw ValidationError("Usage: RouteSync generate|check FIXTURE GENERATED")
    }
    let fixture = try routeFixture(args[1])
    let expected = Data(generatedSource(fixture).utf8)
    if args[0] == "generate" {
        try expected.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    } else {
        guard fixture == Routes.specs.sorted(by: { $0.name < $1.name }) else {
            throw ValidationError("route fixture differs from compiled Swift routes")
        }
        guard try Data(contentsOf: URL(fileURLWithPath: args[2])) == expected else {
            throw ValidationError("generated route source has drifted")
        }
    }
    print("routes \(args[0]) passed (\(fixture.count) entries)")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
