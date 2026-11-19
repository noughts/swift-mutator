import XCTest
@testable import Pricing

final class CartTests: XCTestCase {
    func testSubtotalMultipliesQuantity() {
        var cart = Cart()
        cart.add(LineItem(name: "pen", price: 120, quantity: 3))
        cart.add(LineItem(name: "note", price: 200, quantity: 1))
        XCTAssertEqual(cart.subtotal, 560)
    }

    func testZeroQuantityIsIgnored() {
        var cart = Cart()
        cart.add(LineItem(name: "pen", price: 120, quantity: 0))
        XCTAssertTrue(cart.isEmpty)
    }

    func testCouponReducesTotal() {
        var cart = Cart()
        cart.add(LineItem(name: "bag", price: 1000, quantity: 2))
        XCTAssertEqual(cart.total(couponPercent: 10), 1800)
    }
}
