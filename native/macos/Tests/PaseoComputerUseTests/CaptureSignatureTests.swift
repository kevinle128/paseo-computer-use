import CoreGraphics
import XCTest
@testable import PaseoComputerUseCore

final class CaptureSignatureTests: XCTestCase {
    /// A solid gray image with one lighter rectangle, in pixel coordinates
    /// measured from the top-left corner.
    private func image(width: Int, height: Int, patch: CGRect? = nil) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let patch {
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            // CGContext's origin is the bottom-left corner.
            context.fill(CGRect(
                x: patch.minX,
                y: CGFloat(height) - patch.maxY,
                width: patch.width,
                height: patch.height
            ))
        }
        return context.makeImage()!
    }

    private func changedCells(_ a: [UInt8], _ b: [UInt8], threshold: Int = 12) -> Int {
        zip(a, b).filter { abs(Int($0) - Int($1)) > threshold }.count
    }

    func testSignatureHasTheFixedSize() throws {
        let bytes = try XCTUnwrap(CaptureSignature.bytes(of: image(width: 800, height: 500)))
        XCTAssertEqual(bytes.count, CaptureSignature.byteCount)
        XCTAssertEqual(CaptureSignature.byteCount, 2560)
    }

    func testIdenticalImagesGiveTheSameSignature() throws {
        let a = try XCTUnwrap(CaptureSignature.bytes(of: image(width: 800, height: 500)))
        let b = try XCTUnwrap(CaptureSignature.bytes(of: image(width: 800, height: 500)))
        XCTAssertEqual(a, b)
    }

    func testOneChangedRegionChangesOnlyItsCells() throws {
        let base = try XCTUnwrap(CaptureSignature.bytes(of: image(width: 640, height: 400)))
        // A 160 x 100 patch is a quarter of the width and height: 16 x 10 cells.
        let edited = try XCTUnwrap(CaptureSignature.bytes(
            of: image(width: 640, height: 400, patch: CGRect(x: 0, y: 0, width: 160, height: 100))
        ))
        let changed = changedCells(base, edited)
        XCTAssertGreaterThanOrEqual(changed, 16 * 10 - 40)
        XCTAssertLessThanOrEqual(changed, 17 * 11)
        // The bottom-right corner cell is untouched.
        XCTAssertEqual(base[CaptureSignature.byteCount - 1], edited[CaptureSignature.byteCount - 1])
    }

    func testRegionSignatureSeesOnlyTheRegion() throws {
        let plain = image(width: 640, height: 400)
        let edited = image(width: 640, height: 400, patch: CGRect(x: 0, y: 0, width: 160, height: 100))
        let windowSize = CGSize(width: 320, height: 200)  // a 2x display
        let outside = CGRect(x: 100, y: 60, width: 200, height: 120)
        let inside = CGRect(x: 0, y: 0, width: 80, height: 50)
        XCTAssertEqual(
            CaptureSignature.bytes(of: plain, region: outside, windowSize: windowSize),
            CaptureSignature.bytes(of: edited, region: outside, windowSize: windowSize)
        )
        XCTAssertNotEqual(
            CaptureSignature.bytes(of: plain, region: inside, windowSize: windowSize),
            CaptureSignature.bytes(of: edited, region: inside, windowSize: windowSize)
        )
    }

    func testRegionIsScaledToPixelsAndClippedToTheImage() throws {
        let rect = try XCTUnwrap(CaptureSignature.pixelRect(
            region: CGRect(x: 100, y: 50, width: 500, height: 500),
            windowSize: CGSize(width: 400, height: 200),
            imageSize: CGSize(width: 800, height: 400)
        ))
        XCTAssertEqual(rect, CGRect(x: 200, y: 100, width: 600, height: 300))
    }

    func testRegionOutsideTheWindowIsRefused() {
        XCTAssertNil(CaptureSignature.pixelRect(
            region: CGRect(x: 500, y: 10, width: 50, height: 50),
            windowSize: CGSize(width: 400, height: 200),
            imageSize: CGSize(width: 800, height: 400)
        ))
        XCTAssertNil(CaptureSignature.bytes(
            of: image(width: 800, height: 400),
            region: CGRect(x: 500, y: 10, width: 50, height: 50),
            windowSize: CGSize(width: 400, height: 200)
        ))
    }
}
