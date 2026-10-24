import CoreGraphics

/// Converts between the global display space that CoreGraphics and the
/// accessibility API use (origin at the top-left of the primary display, y
/// grows down) and the AppKit window space (origin at the bottom-left of the
/// primary display, y grows up). Both spaces span every display, so one
/// flip around the primary display height is correct on all of them,
/// including displays with negative origins.
public enum OverlayCoordinateSpace {
    public static func cocoaRect(fromGlobal rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func cocoaPoint(fromGlobal point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// The primary display is the one with the menu bar and global origin
    /// (0, 0). `NSScreen.main` is the display with the key window, which is
    /// the wrong reference for the flip.
    public static func primaryScreenHeight() -> CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }
}
