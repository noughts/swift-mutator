public struct LineItem: Sendable, Equatable {
    public let name: String
    public let price: Int
    public let quantity: Int

    public init(name: String, price: Int, quantity: Int) {
        self.name = name
        self.price = price
        self.quantity = quantity
    }
}

public struct Cart: Sendable {
    public private(set) var items: [LineItem] = []

    public init() {}

    public mutating func add(_ item: LineItem) {
        guard item.quantity > 0 else { return }
        items.append(item)
    }

    public var subtotal: Int {
        items.reduce(0) { $0 + $1.price * $1.quantity }
    }

    /// Total after a percentage coupon, never below zero.
    public func total(couponPercent: Int) -> Int {
        let discount = subtotal * couponPercent / 100
        return max(subtotal - discount, 0)
    }

    public var isEmpty: Bool { items.isEmpty }
}
