import AppKit
import XCTest
@testable import PaseoComputerUseCore

/// Draws a view into an offscreen bitmap at `scale` pixels per point.
@MainActor
private func render(_ view: NSView, scale: CGFloat = 2, background: NSColor? = nil) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(view.bounds.width * scale),
        pixelsHigh: Int(view.bounds.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = view.bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if let background {
        background.setFill()
        view.bounds.fill()
    }
    view.draw(view.bounds)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The largest alpha in a small square around a point in view coordinates
/// (bottom-left origin). A square, not one pixel, because antialiasing and
/// the rounded tip spread the edge over a few pixels.
private func maxAlpha(_ rep: NSBitmapImageRep, around point: CGPoint, radius: Int = 2) -> CGFloat {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    let px = Int(point.x * scale)
    let py = rep.pixelsHigh - 1 - Int(point.y * scale)
    var best: CGFloat = 0
    for x in (px - radius)...(px + radius) {
        for y in (py - radius)...(py + radius) where x >= 0 && y >= 0 && x < rep.pixelsWide && y < rep.pixelsHigh {
            best = max(best, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        }
    }
    return best
}

private func edgeAlpha(_ rep: NSBitmapImageRep) -> CGFloat {
    var best: CGFloat = 0
    for x in 0..<rep.pixelsWide {
        for y in [0, rep.pixelsHigh - 1] {
            best = max(best, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        }
    }
    for y in 0..<rep.pixelsHigh {
        for x in [0, rep.pixelsWide - 1] {
            best = max(best, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        }
    }
    return best
}

@MainActor
final class OverlayRenderingTests: XCTestCase {
    private func pointerView(label: String) -> VirtualCursorCanvasView {
        let view = VirtualCursorCanvasView(frame: NSRect(origin: .zero, size: VirtualCursorCanvasView.viewSize))
        view.label = label
        return view
    }

    func testPointerDrawsAtTheTipAndInsideTheLabel() {
        let view = pointerView(label: "Claude")
        let rep = render(view)
        let tip = VirtualCursorCanvasView.tipPoint
        XCTAssertGreaterThan(maxAlpha(rep, around: tip), 0.3, "the arrow must cover its tip")

        let pill = VirtualCursorCanvasView.labelRect(for: "Claude")
        // Inside the capsule, left of the text, where only the fill shows.
        let insidePill = CGPoint(x: tip.x + pill.minX + 4, y: tip.y + pill.midY)
        XCTAssertGreaterThan(maxAlpha(rep, around: insidePill, radius: 0), 0.5)
        // Well away from the arrow and the capsule nothing is drawn.
        XCTAssertEqual(maxAlpha(rep, around: CGPoint(x: view.bounds.maxX - 3, y: view.bounds.maxY - 3), radius: 1), 0)
    }

    func testPointerIsNotClippedAtRestOrAtTheWidestPose() {
        let view = pointerView(label: "Oh My Pi")
        XCTAssertLessThan(edgeAlpha(render(view)), 0.02)
        // The glide can turn the arrow to any side and stretch it.
        for turn in stride(from: 0.0, to: 360.0, by: 45.0) {
            view.rotationDegrees = MotionConfiguration.live.clickAngle + turn
            view.scaleX = 1.38
            view.scaleY = 0.82
            XCTAssertLessThan(edgeAlpha(render(view)), 0.02, "clipped at a turn of \(turn) degrees")
        }
    }

    func testHaloOutlinesTheWindowEdgeAndLeavesTheInsideClear() {
        let size = CGSize(width: 300 + ScreenHaloView.glowMargin * 2, height: 200 + ScreenHaloView.glowMargin * 2)
        let view = ScreenHaloView(frame: NSRect(origin: .zero, size: size))
        let rep = render(view)
        let window = ScreenHaloView.windowRect(inViewBounds: view.bounds)
        XCTAssertGreaterThan(maxAlpha(rep, around: CGPoint(x: window.midX, y: window.minY + 1), radius: 1), 0.4)
        XCTAssertEqual(maxAlpha(rep, around: CGPoint(x: window.midX, y: window.midY), radius: 4), 0)
        // A soft glow just outside the window edge.
        let glow = maxAlpha(rep, around: CGPoint(x: window.midX, y: window.minY - 3), radius: 0)
        XCTAssertGreaterThan(glow, 0)
        XCTAssertLessThan(glow, 0.4)
    }

    /// Writes a preview of the real views for review. It runs only when
    /// PASEO_POINTER_PREVIEW_PATH names the output file.
    func testWritePreviewWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["PASEO_POINTER_PREVIEW_PATH"] else {
            throw XCTSkip("set PASEO_POINTER_PREVIEW_PATH to write the preview")
        }
        let scale: CGFloat = 3
        let cell = CGSize(width: 360, height: 220)
        let canvas = CGSize(width: cell.width * 2, height: cell.height)
        let image = NSImage(size: canvas)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (index, dark) in [false, true].enumerated() {
            let origin = CGPoint(x: CGFloat(index) * cell.width, y: 0)
            (dark ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)).setFill()
            CGRect(origin: origin, size: cell).fill()
            // A mock window with the halo around it.
            let window = CGRect(x: origin.x + 40, y: origin.y + 30, width: cell.width - 80, height: cell.height - 60)
            (dark ? NSColor(white: 0.20, alpha: 1) : NSColor.white).setFill()
            NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10).fill()
            let halo = ScreenHaloView(frame: NSRect(origin: .zero, size: window.insetBy(dx: -ScreenHaloView.glowMargin, dy: -ScreenHaloView.glowMargin).size))
            drawView(halo, at: window.origin.applying(.init(translationX: -ScreenHaloView.glowMargin, y: -ScreenHaloView.glowMargin)))
            let pointer = pointerView(label: "Claude")
            let tip = CGPoint(x: window.midX - 30, y: window.midY + 20)
            drawView(pointer, at: CGPoint(x: tip.x - VirtualCursorCanvasView.tipPoint.x, y: tip.y - VirtualCursorCanvasView.tipPoint.y))
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func drawView(_ view: NSView, at origin: CGPoint) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        view.draw(view.bounds)
        ctx.restoreGState()
    }
}
