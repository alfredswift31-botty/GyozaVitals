import AppKit
import SwiftUI
import Testing
@testable import GyozaVitals

/// Renders the real views off screen, in light and dark, and writes PNGs that
/// CI prints into its log. Nobody can run the app on a Mac from CI, so this
/// is how a design change is reviewed before it ships.
@MainActor
enum Snapshot {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ui-snapshots", isDirectory: true)

    @discardableResult
    static func render<V: View>(_ view: V, name: String, size: CGSize, dark: Bool) throws -> Data {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = appearance
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        // Render the layer tree: cacheDisplay only captures AppKit drawing and
        // drops SwiftUI's own layers (text and shapes came out blank).
        let scale: CGFloat = 2
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let layer = try #require(host.layer)
        context.cgContext.scaleBy(x: scale, y: scale)
        // The window background isn't part of the host's layers; without it
        // dark text lands on transparent pixels that the JPEG step turns white.
        var background = NSColor.windowBackgroundColor.cgColor
        appearance?.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
        context.cgContext.setFillColor(background)
        context.cgContext.fill(CGRect(origin: .zero, size: size))
        // After a display pass AppKit marks the host layer geometry-flipped;
        // render(in:) ignores that on the root, so undo it here.
        if layer.isGeometryFlipped || layer.contentsAreFlipped() {
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context.cgContext)
        context.flushGraphics()
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        window.contentView = nil
        return data
    }
}
