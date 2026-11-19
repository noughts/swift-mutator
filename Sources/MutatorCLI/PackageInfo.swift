import Foundation

// `swift package describe --type json`: targets with their module names, kinds and sources.

struct PackageDescription: Decodable {
    struct Target: Decodable {
        let name: String
        let c99name: String?
        let type: String
        let path: String
        let sources: [String]?
        let moduleType: String?

        enum CodingKeys: String, CodingKey {
            case name, c99name, type, path, sources
            case moduleType = "module_type"
        }

        var module: String { c99name ?? name }
        var isSwift: Bool { moduleType == nil || moduleType == "SwiftTarget" }
        var swiftSources: [String] { (sources ?? []).filter { $0.hasSuffix(".swift") }.map { "\(path)/\($0)" } }
    }

    let name: String
    let targets: [Target]

    /// Targets whose code runs in tests: libraries and executables (not tests, macros, plugins).
    var codeTargets: [Target] { targets.filter { ["library", "executable"].contains($0.type) && $0.isSwift } }
    var testTargets: [Target] { targets.filter { $0.type == "test" && $0.isSwift } }
}

func describePackage(_ root: URL) async throws -> PackageDescription {
    let result = try await runProcess("swift", ["package", "describe", "--type", "json"], cwd: root)
    guard result.status == 0 else { throw CLIError("swift package describe failed:\n\(result.stderr)") }
    // Warnings may precede the JSON on stdout.
    let json = result.stdout.firstIndex(of: "{").map { String(result.stdout[$0...]) } ?? result.stdout
    return try JSONDecoder().decode(PackageDescription.self, from: Data(json.utf8))
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    var exitCode: Int32 = 1

    init(_ description: String, exitCode: Int32 = 1) {
        self.description = description
        self.exitCode = exitCode
    }
}
