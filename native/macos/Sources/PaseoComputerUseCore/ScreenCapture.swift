import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit

public final class ScreenCapture {
    public static let shared = ScreenCapture()

    private typealias CreateWindowImageFn = @convention(c) (
        CGRect,
         UInt32,
        UInt32,
        UInt32
    ) -> Unmanaged<CGImage>?

    private let createWindowImageFn: CreateWindowImageFn?

    public init() {
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            self.createWindowImageFn = unsafeBitCast(sym, to: CreateWindowImageFn.self)
        } else {
            self.createWindowImageFn = nil
        }
    }

    /// The primary path: capture one window by id, even when other windows cover it. The symbol is loaded at run time
    /// because the SDK marks it unavailable; it can return nil on newer macOS.
    private func captureWithWindowList(windowId: Int) -> CGImage? {
        // kCGWindowListOptionIncludingWindow = 1 << 3 = 8
        // kCGWindowImageBoundsIgnoreFraming = 1 << 0 = 1
        guard let fn = createWindowImageFn,
              let unmanaged = fn(.null, 8, UInt32(windowId), 1) else {
            return nil
        }
        return unmanaged.takeRetainedValue()
    }

    /// How long the ScreenCaptureKit fallback may take before the read goes
    /// on without a screenshot.
    public static let screenCaptureKitTimeoutSeconds: Double = 3.0

    /// The fallback when the primary path returns nil. ScreenCaptureKit is
    /// asynchronous; commands run on a worker thread, so blocking here for a
    /// bounded time does not stall the main thread.
    private func captureWithScreenCaptureKit(windowId: Int) -> CGImage? {
        let result = CapturedImageBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { Int($0.windowID) == windowId }) else {
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let pixelScale = CGFloat(filter.pointPixelScale)
                config.width = max(1, Int(window.frame.width * pixelScale))
                config.height = max(1, Int(window.frame.height * pixelScale))
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                result.set(image)
            } catch {
                // No screenshot; the tree is still returned.
            }
        }
        guard done.wait(timeout: .now() + Self.screenCaptureKitTimeoutSeconds) == .success else {
            return nil
        }
        return result.get()
    }

    /// The window image as captured, before anything is drawn on it. Nil when
    /// Screen Recording is not granted or the window cannot be captured.
    private func captureRawWindowImage(windowId: Int) -> CGImage? {
        guard windowId > 0, CGPreflightScreenCaptureAccess() else {
            return nil
        }
        return captureWithWindowList(windowId: windowId)
            ?? captureWithScreenCaptureKit(windowId: windowId)
    }

    /// The signature of one window image, or of a region of it (window
    /// points). Taken from the raw capture, so the pointer mark that
    /// screenshots carry never counts as a change. Nil when the window cannot
    /// be captured (a failure that may pass); a region outside the window
    /// throws, because no later capture can fix it.
    public func captureSignature(windowId: Int, windowBounds: CGRect, region: CGRect?) throws -> [UInt8]? {
        guard let image = captureRawWindowImage(windowId: windowId) else {
            return nil
        }
        if let region,
           CaptureSignature.pixelRect(
               region: region,
               windowSize: windowBounds.size,
               imageSize: CGSize(width: image.width, height: image.height)
           ) == nil {
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "The region lies outside the window. Give x, y, width, and height in window points."
            )
        }
        return CaptureSignature.bytes(of: image, region: region, windowSize: windowBounds.size)
    }

    public func captureWindowScreenshot(
        windowId: Int,
        windowBounds: CGRect?
    ) -> [String: Any]? {
        guard let rawImage = captureRawWindowImage(windowId: windowId) else {
            return nil
        }
        let width = rawImage.width
        let height = rawImage.height
        guard width > 0, height > 0 else {
            return nil
        }

        let logicalWidth = Double(windowBounds?.width ?? CGFloat(width))
        let scale = logicalWidth > 0 ? Double(width) / logicalWidth : 1.0

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        ctx.draw(rawImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Mark the point the virtual pointer acted on while it is still on
        // screen; a hidden or faded pointer has no position and no mark. The
        // overlay lives on the main thread; capture runs on the command
        // thread, so read the position there.
        let pointerPosition = runOnMainSync { OverlayPresenter.shared.currentPosition }
        if let vpGlobal = pointerPosition,
           let wb = windowBounds,
           wb.contains(vpGlobal) {
            let localX = Double(vpGlobal.x - wb.origin.x) * scale
            let localYFromTop = Double(vpGlobal.y - wb.origin.y) * scale
            let cgY = Double(height) - localYFromTop

            ctx.saveGState()
            let r = 8.0 * scale
            let ringRect = CGRect(x: localX - r, y: cgY - r, width: r * 2.0, height: r * 2.0)
            ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.48, blue: 0.98, alpha: 0.85))
            ctx.fillEllipse(in: ringRect)
            ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.95))
            ctx.setLineWidth(max(1.5, 2.0 * scale))
            ctx.strokeEllipse(in: ringRect)
            ctx.restoreGState()
        }

        guard let composited = ctx.makeImage() else {
            return nil
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, composited, nil)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }

        let base64 = (data as Data).base64EncodedString()
        return [
            "url": "data:image/png;base64,\(base64)",
            "width": Int(windowBounds?.width ?? CGFloat(width)),
            "height": Int(windowBounds?.height ?? CGFloat(height)),
            "scale": scale,
        ]
    }
}

/// Hands the image from the capture task to the waiting command thread.
private final class CapturedImageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?

    func set(_ value: CGImage) {
        lock.lock()
        image = value
        lock.unlock()
    }

    func get() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return image
    }
}
