import Testing
@testable import MutatorCore

@Suite struct FingerprintTests {
    let ids = ["T.CartTests/testAdd", "T.CartTests/testRemove", "T.Suite/check(x:)", "T.free()"]

    private func fingerprints(cart: String = "XCTAssertEqual(add(1), 2)", setUp: String = "", helper: String = "1", privateHelper: String = "1", free: String = "", extraType: String = "", extraIds: [String] = []) -> [String: String] {
        let files = [
            TestSource(path: "Tests/T/CartTests.swift", text: """
            import XCTest
            final class CartTests: XCTestCase {
                \(setUp)
                func testAdd() { \(cart) }
                func testRemove() { XCTAssertTrue(true) }
            }
            \(extraType)
            private func cartFixture() -> Int { \(privateHelper) }
            """),
            TestSource(path: "Tests/T/Other.swift", text: """
            import Testing
            enum Fixtures { static let value = \(helper) }
            @Suite struct Suite { @Test(arguments: [1]) func check(x: Int) { #expect(x == Fixtures.value) } }
            @Test func free() { \(free) }
            """),
        ]
        return testFingerprints(ids: ids + extraIds, modules: ["T": files])
    }

    @Test func editingATestChangesOnlyThatTest() {
        let before = fingerprints()
        let after = fingerprints(cart: "XCTAssertEqual(add(2), 3)")
        #expect(ids.filter { before[$0] != after[$0] } == ["T.CartTests/testAdd"])
    }

    @Test func addingATestTypeChangesNothingElse() {
        let before = fingerprints()
        let after = fingerprints(extraType: "final class More: XCTestCase { func testMore() {} }", extraIds: ["T.More/testMore"])
        #expect(ids.allSatisfy { before[$0] == after[$0] })
    }

    @Test func editingSetUpChangesTheTestsOfItsType() {
        let after = fingerprints(setUp: "override func setUp() { super.setUp() }")
        let before = fingerprints()
        #expect(ids.filter { before[$0] != after[$0] } == ["T.CartTests/testAdd", "T.CartTests/testRemove"])
    }

    @Test func addingOrEditingATestAtTheTopLevelChangesNothingElse() {
        let before = fingerprints()
        #expect(ids.allSatisfy { before[$0] == fingerprints(extraType: "@Test func another() {}", extraIds: ["T.another()"])[$0] })
        let edited = fingerprints(free: "#expect(true)")
        #expect(ids.filter { before[$0] != edited[$0] } == ["T.free()"])
    }

    @Test func editingAPrivateHelperChangesOnlyTheTestsOfItsFile() {
        let before = fingerprints()
        let after = fingerprints(privateHelper: "2")
        #expect(ids.filter { before[$0] != after[$0] } == ["T.CartTests/testAdd", "T.CartTests/testRemove"])
    }

    @Test func editingSharedHelpersChangesEveryTest() {
        let before = fingerprints()
        let after = fingerprints(helper: "2")
        #expect(ids.allSatisfy { before[$0] != after[$0] })
    }
}
