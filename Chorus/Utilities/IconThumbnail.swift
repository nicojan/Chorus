import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks icon data from outside the app (a fetched favicon, an imported
/// setup) to a small PNG before it is stored.
///
/// The rail, the menu bar and the quick switcher decode an icon on every
/// redraw. A small file can still describe a huge image: a 1 MB PNG of one
/// colour at 20000 × 20000 pixels decodes to about 1.6 GB. So the size is read
/// from the file's header first, without decoding, and an image past
/// `maxSourcePixels` is refused. ImageIO then builds the thumbnail straight
/// from the source.
enum IconThumbnail {
    /// 8192 × 8192. Far past any real icon, far short of a decode that hurts.
    static let maxSourcePixels = 8192 * 8192

    /// A PNG no larger than `maxPixelSize` on its long edge, or nil when the
    /// data is not an image ImageIO can read (SVG, for one) or is too large to
    /// decode safely.
    static func png(from data: Data, maxPixelSize: Int = 128, maxSourcePixels: Int = IconThumbnail.maxSourcePixels) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxSourcePixels else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
