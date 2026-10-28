import CoreGraphics
import Foundation

/// A small grayscale thumbnail of a window image, used to tell whether the
/// window changed between two moments without sending the image anywhere.
/// The plugin compares two signatures; the sizes here are mirrored in
/// `wait/signature.ts` and must change together.
public enum CaptureSignature {
    public static let width = 64
    public static let height = 40
    public static var byteCount: Int { width * height }

    /// The pixel rectangle of `region` (window points, top-left origin) inside
    /// an image of `imageSize` pixels that shows a window `windowSize` points
    /// wide and tall. The result is clipped to the image. Returns nil when the
    /// clipped area is smaller than one pixel, so a region outside the window
    /// is an error and never a made-up area.
    public static func pixelRect(region: CGRect, windowSize: CGSize, imageSize: CGSize) -> CGRect? {
        guard windowSize.width > 0, windowSize.height > 0 else { return nil }
        let scaleX = imageSize.width / windowSize.width
        let scaleY = imageSize.height / windowSize.height
        let scaled = CGRect(
            x: region.origin.x * scaleX,
            y: region.origin.y * scaleY,
            width: region.size.width * scaleX,
            height: region.size.height * scaleY
        )
        let clipped = scaled.intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard !clipped.isNull,
              clipped.width >= 1,
              clipped.height >= 1,
              clipped.maxX <= imageSize.width,
              clipped.maxY <= imageSize.height else {
            return nil
        }
        return clipped
    }

    /// Downscales the image to `width` x `height` grayscale bytes, row by row
    /// from the top. Returns nil when the bitmap cannot be created.
    public static func bytes(of image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: byteCount)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// The signature of the whole image, or of `region` when it is given.
    public static func bytes(of image: CGImage, region: CGRect?, windowSize: CGSize) -> [UInt8]? {
        guard let region else { return bytes(of: image) }
        guard let rect = pixelRect(
            region: region,
            windowSize: windowSize,
            imageSize: CGSize(width: image.width, height: image.height)
        ), let cropped = image.cropping(to: rect) else {
            return nil
        }
        return bytes(of: cropped)
    }
}
