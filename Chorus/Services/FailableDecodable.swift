import Foundation

/// Decodes to nil instead of throwing, so one malformed element in an array
/// doesn't fail the whole decode. Each element gets its own decoder, so a
/// caught failure leaves the array decode positioned for the next element.
/// Used by the service catalog and the extension catalog.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
