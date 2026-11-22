#if os(macOS) && DEBUG
import AppKit

/// Test-only: captures the key window to the path in SPINE_SNAPSHOT, three seconds after launch.
/// Lets a headless session see the Mac layout without Screen Recording permission.
enum DebugSnapshot {
    @MainActor
    static func captureAfterDelay() async {
        guard ProcessInfo.processInfo.environment["SPINE_SNAPSHOT"] != nil else { return }
        try? await Task.sleep(for: .seconds(3))
        captureNow()
    }

    @MainActor
    static func captureNow() {
        guard let path = ProcessInfo.processInfo.environment["SPINE_SNAPSHOT"] else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView else { return }

        // A PDF is vector and can reveal SwiftUI content even when the layer render is blank.
        let pdf = view.dataWithPDF(inside: view.bounds)
        try? pdf.write(to: URL(fileURLWithPath: path + ".pdf"))

        // The view tree, for checking which hosts are on screen and where.
        var tree = ""
        func walk(_ node: NSView, depth: Int) {
            tree += String(repeating: "  ", count: depth)
                + "\(type(of: node)) \(String(describing: node.frame))\n"
            for child in node.subviews { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        try? tree.write(toFile: path + ".txt", atomically: true, encoding: .utf8)

        // Render the layer tree. SwiftUI's hosting view is layer-backed, so this catches the
        // chrome and the page's placeholder without Screen Recording permission.
        guard let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: scale, y: -scale)
        layer.render(in: context.cgContext)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
#endif
