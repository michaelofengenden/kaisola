import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// The desktop as it actually looks, captured rather than deduced.
///
/// Every other way of finding the wallpaper asks macOS to *name* it, and for a
/// rotating desktop macOS will not: `desktopImageURL` returns a sentinel, and
/// the wallpaper store records only `shuffle-all-aerials` and a cadence. The
/// pick itself lives in the wallpaper agent. Heuristics on top of that — newest
/// downloaded video, most recently read video — pick the wrong aerial often
/// enough that the glass shows a picture the user is not looking at, which is
/// worse than showing none.
///
/// Capturing sidesteps the question entirely: whatever is on the desktop is
/// what gets baked, whether it is a shuffle, an aerial, a dynamic desktop, a
/// still, or something macOS has not shipped yet.
///
/// **Other apps still never show through.** The filter excludes every on-screen
/// window, so what comes back is the desktop picture alone — the same guarantee
/// the baking pipeline was built to provide, now without having to guess which
/// picture it is.
///
/// Requires the Screen Recording permission. Denied or undecided, this returns
/// nil and the existing resolution ladder runs unchanged, so the feature
/// degrades to exactly today's behaviour rather than to a blank surface.
enum DesktopCaptureSource {
    /// Where the captured frame is written for the bake to read.
    ///
    /// The pipeline downstream is keyed on a file path and its modification
    /// date, so handing it a file — rather than teaching every stage to carry
    /// an image — keeps the cache, the invalidation and the tone map exactly as
    /// they are.
    static var captureURL: URL {
        NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("desktop-capture.png", isDirectory: false)
    }

    /// Whether the app may capture. Never prompts.
    static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Ask once. macOS shows its own prompt and remembers the answer; a second
    /// call after a denial does nothing, which is why this is not retried on a
    /// timer.
    @discardableResult
    static func requestAuthorization() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// One frame of the desktop, with every window excluded.
    ///
    /// - Returns: the file the frame was written to, or nil when capture is not
    ///   permitted or the display cannot be found.
    /// Takes a `CGDirectDisplayID` rather than an `NSScreen` because the call
    /// crosses an actor boundary and `NSScreen` is not `Sendable`.
    static func captureDesktop(displayID: CGDirectDisplayID) async -> URL? {
        guard isAuthorized else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else { return nil }

            // Excluding *every* on-screen window is what leaves the wallpaper
            // by itself. Kaisola's own windows are in that set too, so this
            // cannot capture the glass it is about to draw and feed it back.
            let filter = SCContentFilter(display: display, excludingWindows: content.windows)
            let configuration = SCStreamConfiguration()
            // The bake downsamples to `stillWidth` anyway, so a full-resolution
            // grab would be paid for twice. This is generous enough that the
            // blur has real structure to work from.
            configuration.width = min(display.width, 1_600)
            configuration.height = max(1, Int(
                Double(configuration.width) * Double(display.height) / Double(max(display.width, 1))
            ))
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return write(image)
        } catch {
            return nil
        }
    }

    /// Write the frame where the bake can read it, atomically.
    private static func write(_ image: CGImage) -> URL? {
        let url = captureURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".desktop-capture-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
    }
}

extension NSScreen {
    /// The `CGDirectDisplayID` behind this screen, for matching against
    /// ScreenCaptureKit's displays.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
