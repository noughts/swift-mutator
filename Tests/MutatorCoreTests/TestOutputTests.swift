import Testing
@testable import MutatorCore

@Suite struct TestOutputTests {
    let requested = ["M.CartTests/testA", "M.CartTests/testB", "M.CartTests/testC"]

    @Test func xcTestFailuresOnMacOS() {
        let output = """
        Test Case '-[M.CartTests testA]' started.
        Test Case '-[M.CartTests testA]' passed (0.001 seconds).
        Test Case '-[M.CartTests testB]' started.
        /x/CartTests.swift:9: error: -[M.CartTests testB] : XCTAssertEqual failed
        Test Case '-[M.CartTests testB]' failed (0.002 seconds).
        """
        #expect(failedXCTests(output: output, requested: requested) == ["M.CartTests/testB"])
    }

    @Test func aCrashedXCTestStartedButNeverEnded() {
        let output = """
        Test Case '-[M.CartTests testA]' started.
        Test Case '-[M.CartTests testA]' passed (0.001 seconds).
        Test Case '-[M.CartTests testC]' started.
        Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range
        """
        #expect(failedXCTests(output: output, requested: requested) == ["M.CartTests/testC"])
    }

    @Test func xcTestFailuresOnLinux() {
        let output = """
        Test Case 'CartTests.testA' started at 2026-01-01 00:00:00.000
        Test Case 'CartTests.testA' failed (0.001 seconds)
        """
        #expect(failedXCTests(output: output, requested: requested) == ["M.CartTests/testA"])
    }

    @Test func swiftTestingEventStream() {
        let stream = """
        {"kind":"test","payload":{"id":"M.S","kind":"suite"}}
        {"kind":"event","payload":{"kind":"testStarted","testID":"M.S/ok()/S.swift:3:4"}}
        {"kind":"event","payload":{"kind":"testEnded","testID":"M.S/ok()/S.swift:3:4"}}
        {"kind":"event","payload":{"kind":"testStarted","testID":"M.S/bad(x:)/S.swift:5:4"}}
        {"kind":"event","payload":{"kind":"issueRecorded","testID":"M.S/bad(x:)/S.swift:5:4","issue":{"isKnown":false}}}
        {"kind":"event","payload":{"kind":"testEnded","testID":"M.S/bad(x:)/S.swift:5:4"}}
        {"kind":"event","payload":{"kind":"testStarted","testID":"M.S/crash()/S.swift:7:4"}}
        """
        #expect(failedSwiftTestingTests(eventStream: stream, requested: ["M.S/ok()", "M.S/bad(x:)", "M.S/crash()"]) == ["M.S/bad(x:)", "M.S/crash()"])
    }

    @Test func idsAndFilters() {
        #expect(swiftTestingId("M.S/bad(x:)/S.swift:5:4") == "M.S/bad(x:)")
        #expect(isSwiftTestingId("M.S/bad(x:)"))
        #expect(!isSwiftTestingId("M.CartTests/testA"))
        #expect(swiftTestingFilter("M.S/bad(x:)") == "^M\\.S\\/bad\\(x:\\)(?:/|$)")
        #expect(parseTestList("warning: x\nM.CartTests/testA\nM.free()\n") == ["M.CartTests/testA", "M.free()"])
    }
}
