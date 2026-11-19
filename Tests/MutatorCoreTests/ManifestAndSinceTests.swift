import Testing
@testable import MutatorCore

@Suite struct ManifestTests {
    @Test func localDependenciesBecomeAbsolute() {
        let manifest = """
        let package = Package(
            name: "App",
            dependencies: [
                .package(path: "../Shared"),
                .package(name: "Kit", path: "./Vendor/Kit"),
                .package(path: "/opt/Abs"),
                .package(url: "https://example.com/x.git", from: "1.0.0"),
            ],
            targets: [.target(name: "App", path: "Sources/App")]
        )
        """
        let out = absolutizeLocalDependencies(manifest: manifest, packageRoot: "/work/app")
        #expect(out.contains(#".package(path: "/work/Shared")"#))
        #expect(out.contains(#".package(name: "Kit", path: "/work/app/Vendor/Kit")"#))
        #expect(out.contains(#".package(path: "/opt/Abs")"#))
        #expect(out.contains(#"path: "Sources/App""#))
    }

    @Test func pathsAreNormalized() {
        #expect(resolvePath("../a/./b/../c", base: "/x/y") == "/x/a/c")
        #expect(resolvePath("/abs", base: "/x") == "/abs")
    }
}

@Suite struct SinceTests {
    @Test func killedMutantsWhoseKillersAreGoneAreRechecked() {
        let mutants = analyze(file: "A.swift", source: "func f(_ a: Int) -> Int { a + 1 }").mutants
        let previous = [
            MutantResult(mutant: mutants[0], status: .killed, killedBy: ["M.T/gone"], coveredBy: ["M.T/gone"]),
            MutantResult(mutant: mutants[1], status: .killed, killedBy: ["M.T/here"], coveredBy: ["M.T/here"]),
        ]
        let focus = sinceFocus(touched: ["other"], previous: previous, tests: [TestInfo(id: "M.T/here", fingerprint: "", durationMs: 0)])
        #expect(focus == ["other": .diff, mutants[0].key: .recheck])
    }

    @Test func newFilesAreChangedWhole() {
        let spans = changedSpans(lines: ["A.swift": [2]], newFiles: ["B.swift"], sources: ["A.swift": Array("a\nb\n".utf8), "B.swift": Array("xyz".utf8)])
        #expect(spans["A.swift"] == [Span(start: 2, end: 3)])
        #expect(spans["B.swift"] == [Span(start: 0, end: 3)])
    }
}

@Suite struct RegexTests {
    @Test func mutatesAnchorsQuantifiersClassesAndPredefinedClasses() {
        #expect(regexMutations("^[a-z]+\\d$") == ["[a-z]+\\d$", "^[^a-z]+\\d$", "^[a-z]\\d$", "^[a-z]+\\D$", "^[a-z]+\\d"])
        #expect(regexMutations("a{2,3}") == ["a{2}"])
        #expect(regexMutations("abc").isEmpty)
    }
}
