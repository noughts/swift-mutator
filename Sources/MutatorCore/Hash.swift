/// cyrb53: fast non-cryptographic 53-bit string hash over UTF-16 code units, base36 encoded.
/// Bit-for-bit the same as the `hash` of mizchi/mutator, so keys read the same.
public func stableHash(_ input: String) -> String {
    var h1: UInt32 = 0xdead_beef
    var h2: UInt32 = 0x41c6_ce57
    for unit in input.utf16 {
        let ch = UInt32(unit)
        h1 = (h1 ^ ch) &* 2_654_435_761
        h2 = (h2 ^ ch) &* 1_597_334_677
    }
    h1 = ((h1 ^ (h1 >> 16)) &* 2_246_822_507) ^ ((h2 ^ (h2 >> 13)) &* 3_266_489_909)
    h2 = ((h2 ^ (h2 >> 16)) &* 2_246_822_507) ^ ((h1 ^ (h1 >> 13)) &* 3_266_489_909)
    let value = (UInt64(h2 & 2_097_151) << 32) | UInt64(h1)
    return String(value, radix: 36)
}
