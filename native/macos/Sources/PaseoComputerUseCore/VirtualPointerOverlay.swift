import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public let kPaseoSyntheticEventUserData: Int64 = 0x5041_5345

public struct ShakeDetector: Sendable, Equatable {
    public let reversalThreshold: Int
    public let minSegmentMagnitude: Double
    public let windowDurationSeconds: Double
    public let continuousHoldDurationSeconds: Double

    private var currentSignX: Int = 0
    private var currentSignY: Int = 0
    private var accumulatedX: Double = 0.0
    private var accumulatedY: Double = 0.0
    private var reversalTimestamps: [Double] = []
    private var dragStartTime: Double?

    public init(
        reversalThreshold: Int = 3,
        minSegmentMagnitude: Double = 25.0,
        windowDurationSeconds: Double = 0.38,
        continuousHoldDurationSeconds: Double = 2.0
    ) {
        self.reversalThreshold = reversalThreshold
        self.minSegmentMagnitude = minSegmentMagnitude
        self.windowDurationSeconds = windowDurationSeconds
        self.continuousHoldDurationSeconds = continuousHoldDurationSeconds
    }

    public mutating func reset() {
        currentSignX = 0
        currentSignY = 0
        accumulatedX = 0.0
        accumulatedY = 0.0
        reversalTimestamps.removeAll()
        dragStartTime = nil
    }

    public mutating func recordMouseDelta(
        dx: Double,
        dy: Double,
        isDragging: Bool = false,
        timestamp: Double
    ) -> Bool {
        // Prune expired reversals outside the 380ms sliding window
        reversalTimestamps.removeAll { timestamp - $0 > windowDurationSeconds }

        if isDragging {
            if let start = dragStartTime {
                if timestamp - start >= continuousHoldDurationSeconds {
                    return true
                }
            } else {
                dragStartTime = timestamp
            }
        } else {
            dragStartTime = nil
        }

        let signX = dx > 0.5 ? 1 : (dx < -0.5 ? -1 : 0)
        if signX != 0 {
            if currentSignX == 0 {
                currentSignX = signX
                accumulatedX = abs(dx)
            } else if signX == currentSignX {
                accumulatedX += abs(dx)
            } else {
                if accumulatedX >= minSegmentMagnitude && abs(dx) >= minSegmentMagnitude {
                    reversalTimestamps.append(timestamp)
                    currentSignX = signX
                    accumulatedX = abs(dx)
                } else if accumulatedX >= minSegmentMagnitude {
                    currentSignX = signX
                    accumulatedX = abs(dx)
                    if accumulatedX >= minSegmentMagnitude {
                        reversalTimestamps.append(timestamp)
                    }
                } else {
                    currentSignX = signX
                    accumulatedX = abs(dx)
                }
            }
        }

        let signY = dy > 0.5 ? 1 : (dy < -0.5 ? -1 : 0)
        if signY != 0 {
            if currentSignY == 0 {
                currentSignY = signY
                accumulatedY = abs(dy)
            } else if signY == currentSignY {
                accumulatedY += abs(dy)
            } else {
                if accumulatedY >= minSegmentMagnitude && abs(dy) >= minSegmentMagnitude {
                    reversalTimestamps.append(timestamp)
                    currentSignY = signY
                    accumulatedY = abs(dy)
                } else {
                    currentSignY = signY
                    accumulatedY = abs(dy)
                }
            }
        }

        return reversalTimestamps.count >= reversalThreshold
    }
}

private func overlayColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

/// The virtual pointer: a soft, translucent blue arrow with a white rim and
/// a capsule next to it that names the agent in control.
///
/// The view draws in points with the arrow tip at `tipPoint`. Motion turns
/// and stretches the arrow around its tip, so the tip always stays on the
/// target point; the capsule stays upright so the name is always readable.
@MainActor
final class VirtualCursorCanvasView: NSView {
    /// Room around the tip that the turned, stretched arrow and its glow can
    /// use. The glide leans the arrow a few degrees from its resting angle, and
    /// with the largest stretch and the glow it reaches about 32 points from
    /// the tip.
    nonisolated static let tipInsetLeft: CGFloat = 34
    nonisolated static let tipInsetTop: CGFloat = 34
    nonisolated static let tipInsetBottom: CGFloat = 36
    /// The capsule sits at this offset from the tip, below and to the right.
    nonisolated static let labelOrigin = CGPoint(x: 13, y: -31)
    nonisolated static let labelHeight: CGFloat = 18
    nonisolated static let labelPadding: CGFloat = 8
    /// The widest capsule. A longer name is cut with an ellipsis instead of
    /// clipped at the panel edge.
    nonisolated static let labelMaxWidth: CGFloat = 92
    nonisolated static let viewSize = CGSize(
        width: tipInsetLeft + labelOrigin.x + labelMaxWidth + 4,
        height: tipInsetTop + tipInsetBottom
    )
    /// The tip in view coordinates (bottom-left origin, y grows up).
    nonisolated static let tipPoint = CGPoint(x: tipInsetLeft, y: tipInsetBottom)

    var rotationDegrees: Double = MotionConfiguration.live.clickAngle
    var scaleX: Double = 1.0
    var scaleY: Double = 1.0
    var pulseScale: Double = 1.0
    var label: String = OverlayPresenter.defaultLabel

    override var isOpaque: Bool { false }

    private static let fillTop = overlayColor(150, 190, 252, 0.66)
    private static let fillBottom = overlayColor(100, 150, 236, 0.66)
    private static let rim = CGColor(gray: 1, alpha: 0.85)
    private static let rimWidth: CGFloat = 1.3
    private static let glow = overlayColor(110, 160, 255, 0.30)
    private static let labelTop = overlayColor(146, 186, 250, 0.64)
    private static let labelBottom = overlayColor(100, 150, 236, 0.64)

    /// The arrow outline with the tip at the origin (y grows up). Each
    /// corner is rounded with a tangent arc; the tip gets the smallest
    /// radius so it stays sharp enough to point at a precise spot.
    nonisolated static func arrowPath(radius: CGFloat = 2.0) -> CGPath {
        let vertices = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 2.6, y: -16.6),
            CGPoint(x: 6.6, y: -11.2),
            CGPoint(x: 13.6, y: -10.2),
        ]
        let cornerFactors: [CGFloat] = [0.45, 1.1, 0.9, 1.1]
        let path = CGMutablePath()
        let last = vertices[vertices.count - 1]
        path.move(to: CGPoint(x: (last.x + vertices[0].x) / 2, y: (last.y + vertices[0].y) / 2))
        for index in vertices.indices {
            let next = vertices[(index + 1) % vertices.count]
            path.addArc(tangent1End: vertices[index], tangent2End: next, radius: radius * cornerFactors[index])
        }
        path.closeSubpath()
        return path
    }

    nonisolated static func labelFont() -> NSFont {
        NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    }

    /// The capsule frame relative to the tip for a label text.
    nonisolated static func labelRect(for text: String) -> CGRect {
        let textWidth = (text as NSString).size(withAttributes: [.font: labelFont()]).width
        let width = min(labelMaxWidth, ceil(textWidth) + labelPadding * 2)
        return CGRect(x: labelOrigin.x, y: labelOrigin.y, width: width, height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: Self.tipPoint.x, y: Self.tipPoint.y)
        drawArrow(in: ctx)
        drawLabel(in: ctx)
        ctx.restoreGState()
    }

    private func drawArrow(in ctx: CGContext) {
        ctx.saveGState()
        // The drawing already points the way the pointer rests, so only the
        // turn away from the rest angle is applied.
        let turn = rotationDegrees - MotionConfiguration.live.clickAngle
        ctx.rotate(by: CGFloat(turn * .pi / 180.0))
        ctx.scaleBy(x: CGFloat(scaleX * pulseScale), y: CGFloat(scaleY * pulseScale))

        let path = Self.arrowPath()
        ctx.setLineJoin(.round)
        ctx.setLineWidth(Self.rimWidth * 2)
        ctx.setStrokeColor(Self.rim)

        // The rim is stroked at twice its width behind the fill, so half of
        // it shows outside the arrow. The first pass also casts the glow.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 9, color: Self.glow)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [Self.fillTop, Self.fillBottom] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 6, y: -17), options: [])
        }
        // A thin highlight along the left edge gives the glass look.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: 0.9, y: -2.5))
        ctx.addLine(to: CGPoint(x: 2.6, y: -13))
        ctx.strokePath()
        ctx.restoreGState()

        ctx.restoreGState()
    }

    private func drawLabel(in ctx: CGContext) {
        let pill = Self.labelRect(for: label)
        let radius = pill.height / 2
        let pillPath = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(pillPath)
        ctx.setFillColor(Self.labelBottom)
        ctx.fillPath()
        ctx.addPath(pillPath)
        ctx.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [Self.labelTop, Self.labelBottom] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: pill.maxY),
                end: CGPoint(x: 0, y: pill.minY),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        ctx.setLineWidth(0.6)
        let border = pill.insetBy(dx: 0.3, dy: 0.3)
        ctx.addPath(CGPath(roundedRect: border, cornerWidth: radius - 0.3, cornerHeight: radius - 0.3, transform: nil))
        ctx.strokePath()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let textRect = CGRect(
            x: pill.minX + Self.labelPadding,
            y: pill.minY + 2.6,
            width: pill.width - Self.labelPadding * 2,
            // One line high, so the text sits where the approved design puts
            // its baseline instead of at the top of a taller box.
            height: ceil(Self.labelFont().ascender - Self.labelFont().descender + Self.labelFont().leading)
        )
        (label as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: Self.labelFont(),
                .foregroundColor: NSColor.white,
                .kern: 0.15,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

/// The outline around the window the agent acts on: a soft blue line on the
/// window edge with a faint glow outside it. The panel is larger than the
/// window by `glowMargin` on every side so the glow is not cut off.
@MainActor
final class ScreenHaloView: NSView {
    nonisolated static let glowMargin: CGFloat = 12
    nonisolated static let cornerRadius: CGFloat = 10
    nonisolated static let lineWidth: CGFloat = 2

    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// The window bounds inside the view.
    nonisolated static func windowRect(inViewBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: glowMargin, dy: glowMargin)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let window = Self.windowRect(inViewBounds: bounds)
        guard window.width > 0, window.height > 0 else { return }
        // The line lies just inside the window edge.
        let lineRect = window.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        let radius = Self.cornerRadius
        let line = CGPath(roundedRect: lineRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // The glow pass is clipped to the area outside the window, so the
        // window content is not tinted; only its shadow shows there.
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: .zero, blur: 10, color: overlayColor(120, 170, 255, 0.25))
        ctx.setStrokeColor(overlayColor(120, 170, 255, 1))
        ctx.setLineWidth(Self.lineWidth)
        ctx.addPath(line)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(overlayColor(120, 170, 255, 0.55))
        ctx.setLineWidth(Self.lineWidth)
        ctx.addPath(line)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// Shows overlay frames in two click-through panels: the halo around the
/// target window and the virtual pointer. The panels never take focus, are
/// left out of screenshots and screen sharing, and never move the real
/// cursor.
@MainActor
public final class PanelOverlaySurface: OverlaySurface {
    private var haloPanel: NSPanel?
    private var pointerPanel: NSPanel?
    private let canvasView = VirtualCursorCanvasView(
        frame: NSRect(origin: .zero, size: VirtualCursorCanvasView.viewSize)
    )

    public init() {}

    /// The halo panel frame in AppKit coordinates for a window in global
    /// display coordinates: the window plus room for the glow on each side.
    public nonisolated static func haloPanelFrame(forWindow window: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let margin = ScreenHaloView.glowMargin
        return OverlayCoordinateSpace.cocoaRect(fromGlobal: window, primaryScreenHeight: primaryScreenHeight)
            .insetBy(dx: -margin, dy: -margin)
    }

    /// The pointer panel frame in AppKit coordinates. The arrow tip, at
    /// `VirtualCursorCanvasView.tipPoint` in the panel, is on the point.
    public nonisolated static func pointerPanelFrame(forPoint point: CGPoint, primaryScreenHeight: CGFloat) -> CGRect {
        let tip = OverlayCoordinateSpace.cocoaPoint(fromGlobal: point, primaryScreenHeight: primaryScreenHeight)
        let offset = VirtualCursorCanvasView.tipPoint
        return CGRect(origin: CGPoint(x: tip.x - offset.x, y: tip.y - offset.y), size: VirtualCursorCanvasView.viewSize)
    }

    private static func makePanel(contentView: NSView) -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(
            contentRect: contentView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // No zoom when the panel is shown or hidden: the halo must have the
        // window's bounds from its first frame, and the fade is drawn here.
        panel.animationBehavior = .none
        panel.contentView = contentView
        return panel
    }

    public func render(_ frame: OverlayFrame) {
        let primaryHeight = OverlayCoordinateSpace.primaryScreenHeight()

        if let window = frame.haloFrame, window.width > 0, window.height > 0 {
            let panel: NSPanel
            if let existing = haloPanel {
                panel = existing
            } else {
                let view = ScreenHaloView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
                view.autoresizingMask = [.width, .height]
                panel = Self.makePanel(contentView: view)
                haloPanel = panel
            }
            let target = Self.haloPanelFrame(forWindow: window, primaryScreenHeight: primaryHeight)
            if panel.frame != target {
                panel.setFrame(target, display: true)
            }
            panel.alphaValue = CGFloat(frame.alpha)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else {
            haloPanel?.orderOut(nil)
        }

        if let pointer = frame.pointer {
            let panel: NSPanel
            if let existing = pointerPanel {
                panel = existing
            } else {
                panel = Self.makePanel(contentView: canvasView)
                pointerPanel = panel
            }
            canvasView.rotationDegrees = pointer.rotationDegrees
            canvasView.scaleX = pointer.scaleX
            canvasView.scaleY = pointer.scaleY
            canvasView.pulseScale = pointer.pulseScale
            canvasView.label = pointer.label
            canvasView.needsDisplay = true
            panel.setFrameOrigin(Self.pointerPanelFrame(forPoint: pointer.position, primaryScreenHeight: primaryHeight).origin)
            panel.alphaValue = CGFloat(frame.alpha * pointer.alpha)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else {
            pointerPanel?.orderOut(nil)
        }
    }

    public func hide() {
        haloPanel?.orderOut(nil)
        pointerPanel?.orderOut(nil)
    }
}

public final class UserInputEscapeMonitor {
    public enum AbortReason: String, Sendable {
        case escapeKey = "escape_key"
        case userIntervened = "user_intervened"
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shakeDetector = ShakeDetector()
    private let onAbort: (AbortReason) -> Void
    public private(set) var isArmed: Bool = false

    public init(onAbort: @escaping (AbortReason) -> Void) {
        self.onAbort = onAbort
    }

    @discardableResult
    public func arm() -> Bool {
        if isArmed { return true }
        guard AXIsProcessTrusted() else {
            return false
        }

        shakeDetector.reset()
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<UserInputEscapeMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isArmed = true
        return true
    }

    public func disarm() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isArmed = false
        shakeDetector.reset()
    }

    static let escapeKeyCode: Int64 = 53

    /// Pointer events from the mouse or trackpad have no source process.
    /// Any event with a source pid was posted by software.
    public static func isHardwarePointerEvent(sourcePid: Int64) -> Bool {
        sourcePid == 0
    }

    /// A held key repeats keyDown with the autorepeat flag set. Only the
    /// first keyDown of a press is a new stop, so one press gives one abort.
    public static func isNewEscapePress(keyCode: Int64, autorepeat: Int64) -> Bool {
        keyCode == escapeKeyCode && autorepeat == 0
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore synthetic events generated by InputDriver
        if event.getIntegerValueField(.eventSourceUserData) == kPaseoSyntheticEventUserData {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escapeKeyCode {
                // Consume every physical Escape keyDown, but abort only on
                // the first one of a press.
                let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                if Self.isNewEscapePress(keyCode: keyCode, autorepeat: autorepeat) {
                    onAbort(.escapeKey)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
            // Only the user's own hand on the mouse is a takeover. Events that
            // another process posted (an automation tool, a remote session)
            // carry that process's pid and must not stop the agent.
            let sourcePid = event.getIntegerValueField(.eventSourceUnixProcessID)
            guard Self.isHardwarePointerEvent(sourcePid: sourcePid) else {
                return Unmanaged.passUnretained(event)
            }
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            let isDragging = (type == .leftMouseDragged || type == .rightMouseDragged)
            let now = ProcessInfo.processInfo.systemUptime
            if shakeDetector.recordMouseDelta(dx: dx, dy: dy, isDragging: isDragging, timestamp: now) {
                onAbort(.userIntervened)
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
