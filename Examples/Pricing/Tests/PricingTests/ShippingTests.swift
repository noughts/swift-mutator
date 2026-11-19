import Testing
@testable import Pricing

@Suite struct ShippingTests {
    @Test func expressAlwaysCosts() {
        #expect(shippingFee(subtotal: 10000, express: true) == 800)
    }

    @Test func freeAboveThreshold() {
        #expect(shippingFee(subtotal: 6000, express: false) == 0)
    }

    @Test(arguments: [100, 4999])
    func standardBelowThreshold(subtotal: Int) {
        #expect(shippingFee(subtotal: subtotal, express: false) == 300)
    }
}

@Test func normalizesCodes() {
    #expect(normalizedCode("abc") == "ABC")
    #expect(normalizedCode(nil) == nil)
}
