import CoreGraphics
import XCTest
@testable import PaseoComputerUseCore

@MainActor
private final class RecordingSurface: OverlaySurface {
    var frames: [OverlayFrame] = []
    var hideCount = 0

    func render(_ frame: OverlayFrame) { frames.append(frame) }
    func hide() { hideCount += 1 }
}

@MainActor
private final class ManualScheduler: OverlayFrameScheduler {
    private(set) var isRunning = false
    func start(_ onFrame: @escaping @MainActor () -> Void) { isRunning = true }
    func stop() { isRunning = false }
}

@MainActor
final class OverlayPresenterTests: XCTestCase {
    private var now: TimeInterval = 100
    private var surface: RecordingSurface!
    private var scheduler: ManualScheduler!
    private var presenter: OverlayPresenter!

    private let window = CGRect(x: 200, y: 150, width: 800, height: 600)

    override func setUp() async throws {
        now = 100
        surface = RecordingSurface()
        scheduler = ManualScheduler()
        presenter = OverlayPresenter(surface: surface, scheduler: scheduler, clock: { [unowned self] in self.now })
    }

    /// Advances the clock in display frames and ticks the presenter.
    private func run(seconds: Double, fps: Double = 120) {
        let frames = Int((seconds * fps).rounded())
        for _ in 0..<frames {
            now += 1.0 / fps
            presenter.tick()
        }
    }

    func testThePointerShowsTheDefaultLabelUntilAnAgentIsNamed() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        XCTAssertEqual(surface.frames.last?.pointer?.label, "Agent")
    }

    func testPresenterKeepsTheLastLabelAcrossMovesAndHides() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window, label: "Codex")
        XCTAssertEqual(surface.frames.last?.pointer?.label, "Codex")
        // A command without a label keeps the last one.
        presenter.pointerMove(to: CGPoint(x: 400, y: 300), window: window)
        XCTAssertEqual(surface.frames.last?.pointer?.label, "Codex")
        presenter.pointerMove(to: CGPoint(x: 410, y: 310), window: window, label: "  ")
        XCTAssertEqual(presenter.label, "Codex")

        presenter.hide()
        run(seconds: 0.5)
        XCTAssertEqual(presenter.state, .hidden)
        presenter.pointerMove(to: CGPoint(x: 500, y: 300), window: window)
        XCTAssertEqual(surface.frames.last?.pointer?.label, "Codex")

        presenter.pointerMove(to: CGPoint(x: 520, y: 320), window: window, label: "Oh My Pi")
        XCTAssertEqual(surface.frames.last?.pointer?.label, "Oh My Pi")
    }

    func testStartsHiddenWithNoPosition() {
        XCTAssertEqual(presenter.state, .hidden)
        XCTAssertNil(presenter.currentPosition)
        XCTAssertFalse(scheduler.isRunning)
    }

    func testMoveShowsTheHaloOnTheTargetWindowAndStartsFrames() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        XCTAssertEqual(presenter.state, .active)
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(surface.frames.last?.haloFrame, window)
        XCTAssertEqual(presenter.currentPosition, CGPoint(x: 300, y: 200))
    }

    func testMoveWithoutATargetWindowShowsNoHalo() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: nil)
        XCTAssertNil(surface.frames.last?.haloFrame)
    }

    func testGlideShowsSeveralIntermediatePositionsAndEndsOnTheTarget() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 0.05)
        presenter.pointerMove(to: CGPoint(x: 900, y: 700), window: window)
        run(seconds: 1.0)
        let positions = surface.frames.compactMap { $0.pointer?.position }
        let distinct = Set(positions.map { "\(Int($0.x)),\(Int($0.y))" })
        XCTAssertGreaterThan(distinct.count, 10, "the glide must render many frames, not jump")
        XCTAssertEqual(positions.last, CGPoint(x: 900, y: 700))
    }

    func testANewMoveCancelsTheGlideAndStartsFromWhereThePointerIs() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 0.05)
        presenter.pointerMove(to: CGPoint(x: 900, y: 700), window: window)
        run(seconds: 0.1)
        let midway = surface.frames.last!.pointer!.position
        XCTAssertNotEqual(midway, CGPoint(x: 900, y: 700))

        presenter.pointerMove(to: CGPoint(x: 250, y: 650), window: window)
        // The first frame of the new glide starts where the old one was.
        XCTAssertEqual(surface.frames.last?.pointer?.position, midway)
        run(seconds: 1.0)
        XCTAssertEqual(surface.frames.last?.pointer?.position, CGPoint(x: 250, y: 650))
        XCTAssertFalse(surface.frames.contains { $0.pointer?.position == CGPoint(x: 900, y: 700) })
    }

    func testPulsePlaysOnlyAfterThePointerArrives() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 0.05)
        presenter.pointerMove(to: CGPoint(x: 900, y: 700), window: window)
        presenter.pulse()
        run(seconds: 0.1)
        XCTAssertTrue(surface.frames.allSatisfy { ($0.pointer?.pulseScale ?? 1.0) == 1.0 })
        run(seconds: 1.0)
        let pulsed = surface.frames.filter { ($0.pointer?.pulseScale ?? 1.0) < 1.0 }
        XCTAssertFalse(pulsed.isEmpty)
        XCTAssertTrue(pulsed.allSatisfy { $0.pointer?.position == CGPoint(x: 900, y: 700) })
    }

    func testPointerHoldsAtTheClickPointThenFadesWhileTheHaloStays() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 1.0)
        XCTAssertEqual(surface.frames.last?.pointer?.alpha, 1.0)
        XCTAssertEqual(presenter.currentPosition, CGPoint(x: 300, y: 200))
        // The hold counts from when the pointer arrived, then the fade runs.
        run(seconds: 1.5)
        XCTAssertNil(surface.frames.last?.pointer, "the pointer fades about 1.5 s after it arrives")
        XCTAssertNil(presenter.currentPosition)
        XCTAssertEqual(surface.frames.last?.haloFrame, window)
        XCTAssertEqual(presenter.state, .active)
    }

    func testHideFadesThenHidesAndClearsThePosition() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 0.2)
        presenter.hide()
        XCTAssertEqual(presenter.state, .fading)
        run(seconds: 0.1)
        let fading = surface.frames.last!
        XCTAssertLessThan(fading.alpha, 1.0)
        XCTAssertGreaterThan(fading.alpha, 0.0)
        run(seconds: 0.3)
        XCTAssertEqual(presenter.state, .hidden)
        XCTAssertEqual(surface.hideCount, 1)
        XCTAssertNil(presenter.currentPosition)
        XCTAssertFalse(scheduler.isRunning)
    }

    func testHideWhenHiddenDoesNothing() {
        presenter.hide()
        XCTAssertEqual(presenter.state, .hidden)
        XCTAssertTrue(surface.frames.isEmpty)
    }

    func testAMoveDuringTheFadeShowsTheOverlayAgain() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        presenter.hide()
        run(seconds: 0.1)
        presenter.pointerMove(to: CGPoint(x: 400, y: 300), window: window)
        XCTAssertEqual(presenter.state, .active)
        XCTAssertEqual(surface.frames.last?.alpha, 1.0)
    }

    func testWatchdogHidesTheOverlayWhenNoHideArrives() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 4.5, fps: 60)
        XCTAssertEqual(presenter.state, .active)
        // Five seconds after the glide ended, plus the fade.
        run(seconds: 1.5, fps: 60)
        XCTAssertEqual(presenter.state, .hidden)
        XCTAssertEqual(surface.hideCount, 1)
        XCTAssertNil(presenter.currentPosition)
        XCTAssertFalse(scheduler.isRunning)
    }

    func testActivityRestartsTheWatchdog() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 4.0, fps: 60)
        presenter.pointerMove(to: CGPoint(x: 320, y: 220), window: window)
        run(seconds: 4.0, fps: 60)
        XCTAssertEqual(presenter.state, .active)
    }

    func testKeepAliveDuringALongTypingActionKeepsTheHaloUp() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        // A type_text that runs for 8 s after the click marks activity
        // about once a second.
        for _ in 0..<8 {
            run(seconds: 1.0, fps: 60)
            presenter.keepAlive()
        }
        XCTAssertEqual(presenter.state, .active)
        XCTAssertEqual(surface.frames.last?.haloFrame, window)
        XCTAssertEqual(surface.hideCount, 0)
        // The pointer marks the click point only, so it still fades.
        XCTAssertNil(presenter.currentPosition)
        // When the typing stops, the watchdog hides the overlay again.
        run(seconds: 5.5, fps: 60)
        XCTAssertEqual(presenter.state, .hidden)
        XCTAssertEqual(surface.hideCount, 1)
    }

    func testKeepAliveNeverShowsAHiddenOrFadingOverlay() {
        presenter.keepAlive()
        XCTAssertEqual(presenter.state, .hidden)
        XCTAssertTrue(surface.frames.isEmpty)

        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        presenter.hide()
        run(seconds: 0.1)
        presenter.keepAlive()
        XCTAssertEqual(presenter.state, .fading)
        run(seconds: 0.3)
        XCTAssertEqual(presenter.state, .hidden)
    }

    func testAnUnchangedOverlayIsNotRedrawnEveryFrame() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 3.0)
        let settled = surface.frames.count
        // The pointer has faded and only the static halo remains.
        run(seconds: 1.0)
        XCTAssertEqual(surface.frames.count, settled)
        XCTAssertEqual(presenter.state, .active)
    }

    func testTheFirstFrameAfterAHideIsDrawnEvenWhenItEqualsTheLastOne() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 1.0)
        presenter.hide()
        run(seconds: 0.5)
        let before = surface.frames.count
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        XCTAssertEqual(surface.frames.count, before + 1)
        XCTAssertEqual(surface.frames.last?.haloFrame, window)
    }

    func testTheNextGlideAfterAHideStartsWhereThePointerWasLastShown() {
        presenter.pointerMove(to: CGPoint(x: 300, y: 200), window: window)
        run(seconds: 1.0)
        presenter.hide()
        run(seconds: 0.5)
        presenter.pointerMove(to: CGPoint(x: 900, y: 700), window: window)
        XCTAssertEqual(surface.frames.last?.pointer?.position, CGPoint(x: 300, y: 200))
    }
}

final class PointerAnimatorTests: XCTestCase {
    func testEmitsManyIntermediateFramesBeforeItSettles() {
        var glide = PointerAnimator(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 600, y: 400),
            bounds: CGRect(x: -100, y: -100, width: 800, height: 600)
        )
        var positions: [CGPoint] = []
        while !glide.isFinished, positions.count < 1_000 {
            positions.append(glide.advance(by: 1.0 / 60.0).position)
        }
        XCTAssertGreaterThan(positions.count, 10)
        XCTAssertEqual(positions.last, CGPoint(x: 600, y: 400))
        XCTAssertGreaterThan(Set(positions.map { "\($0.x),\($0.y)" }).count, 10)
    }

    func testEndsOnTheTargetWithinItsMaximumDuration() {
        var glide = PointerAnimator(
            from: CGPoint(x: -1000, y: -200),
            to: CGPoint(x: 2500, y: 1500),
            bounds: CGRect(x: -1100, y: -300, width: 3700, height: 1900),
            maxDuration: 0.9
        )
        for _ in 0..<60 { glide.advance(by: 1.0 / 60.0) }
        XCTAssertTrue(glide.isFinished)
        XCTAssertEqual(glide.sample.position, CGPoint(x: 2500, y: 1500))
    }

    func testAMoveToTheSamePointIsAlreadyFinished() {
        let glide = PointerAnimator(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5), bounds: .zero)
        XCTAssertTrue(glide.isFinished)
    }
}

/// The user's layout: a 1920x1080 primary display, a portrait display to the
/// right that starts above it, and a portrait display to the left.
final class OverlayCoordinateSpaceTests: XCTestCase {
    let primaryHeight: CGFloat = 1080

    func testConvertsEachDisplayOfTheThreeDisplayLayout() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: -323, width: 1080, height: 1920)
        let left = CGRect(x: -1080, y: -236, width: 1080, height: 1920)
        XCTAssertEqual(OverlayCoordinateSpace.cocoaRect(fromGlobal: main, primaryScreenHeight: primaryHeight), main)
        XCTAssertEqual(
            OverlayCoordinateSpace.cocoaRect(fromGlobal: right, primaryScreenHeight: primaryHeight),
            CGRect(x: 1920, y: -517, width: 1080, height: 1920)
        )
        XCTAssertEqual(
            OverlayCoordinateSpace.cocoaRect(fromGlobal: left, primaryScreenHeight: primaryHeight),
            CGRect(x: -1080, y: -604, width: 1080, height: 1920)
        )
    }

    func testHaloOutlineIsTheTargetWindowFrameOnEveryDisplay() {
        let windows = [
            CGRect(x: 100, y: 80, width: 900, height: 700),
            CGRect(x: 2000, y: -200, width: 900, height: 1200),
            CGRect(x: -1000, y: 1400, width: 800, height: 200),
        ]
        for window in windows {
            let panel = PanelOverlaySurface.haloPanelFrame(forWindow: window, primaryScreenHeight: primaryHeight)
            // The view draws the outline on the window rect inside the panel.
            let local = ScreenHaloView.windowRect(inViewBounds: CGRect(origin: .zero, size: panel.size))
            let outline = local.offsetBy(dx: panel.minX, dy: panel.minY)
            XCTAssertEqual(outline.size, window.size)
            XCTAssertEqual(outline.minX, window.minX)
            // Back to global coordinates, the outline covers the window exactly.
            XCTAssertEqual(primaryHeight - outline.maxY, window.minY)
            // The panel is larger only by the glow margin.
            XCTAssertEqual(panel.width, window.width + ScreenHaloView.glowMargin * 2)
        }
    }

    func testPointerTipIsOnThePointOnEachDisplayOfTheThreeDisplayLayout() {
        // Points on the primary display, near the top of the right display
        // (above the primary one), and low on the left display.
        let points = [
            (CGPoint(x: 960, y: 540), CGPoint(x: 960, y: 540)),
            (CGPoint(x: 2400, y: -300), CGPoint(x: 2400, y: 1380)),
            (CGPoint(x: -500, y: 1600), CGPoint(x: -500, y: -520)),
        ]
        for (point, cocoa) in points {
            let panel = PanelOverlaySurface.pointerPanelFrame(forPoint: point, primaryScreenHeight: primaryHeight)
            let tip = VirtualCursorCanvasView.tipPoint
            XCTAssertEqual(panel.minX + tip.x, cocoa.x)
            XCTAssertEqual(panel.minY + tip.y, cocoa.y)
            XCTAssertEqual(panel.size, VirtualCursorCanvasView.viewSize)
        }
    }

    func testPointerPanelHoldsTheWidestLabelAndTheTurnedArrow() {
        let size = VirtualCursorCanvasView.viewSize
        let tip = VirtualCursorCanvasView.tipPoint
        let widest = VirtualCursorCanvasView.labelRect(for: "Oh My Pi")
        XCTAssertLessThan(widest.width, VirtualCursorCanvasView.labelMaxWidth)
        XCTAssertLessThanOrEqual(tip.x + widest.maxX, size.width)
        XCTAssertGreaterThanOrEqual(tip.y + widest.minY, 0)
        // Room for the arrow and glow in every direction from the tip.
        XCTAssertGreaterThanOrEqual(tip.x, 32)
        XCTAssertGreaterThanOrEqual(size.height - tip.y, 32)
        XCTAssertGreaterThanOrEqual(tip.y, 32)
    }
}
