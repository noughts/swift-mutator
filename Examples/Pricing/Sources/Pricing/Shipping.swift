/// Free standard shipping from 5000 yen; express always costs.
public func shippingFee(subtotal: Int, express: Bool) -> Int {
    if subtotal >= 5000 && !express { return 0 }
    return express ? 800 : 300
}

public func shippingLabel(fee: Int) -> String {
    fee == 0 ? "Free shipping" : "Shipping: \(fee) yen"
}

public func normalizedCode(_ code: String?) -> String? {
    guard let code, !code.isEmpty else { return nil }
    // mutator-disable-next-line MethodExpression: codes are case-insensitive by spec
    return code.uppercased()
}
