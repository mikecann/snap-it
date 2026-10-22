import AppKit
import SnapItCore

/// Saving, the clipboard and the shutter sound.
enum Output {
    /// All PNG writes go through one serial queue, so a later save of the same file always wins.
    static let io = DispatchQueue(label: "snap-it.io", qos: .userInitiated)

    private static let shutter: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    static func playShutter() {
        guard let shutter else { return }
        shutter.stop()
        shutter.play()
    }

    /// The encoded PNG (nil if encoding failed) and whether it reached the disk.
    struct WriteResult {
        let data: Data?
        let saved: Bool
    }

    /// Encodes and writes on the IO queue, then calls back on the main queue.
    static func write(_ image: CGImage, scale: CGFloat, to url: URL, completion: @escaping @MainActor (WriteResult) -> Void) {
        io.async {
            let result = encodeAndWrite(image, scale: scale, to: url)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Writes synchronously, for drag-out where the file must exist before the drag starts, and for quitting.
    static func writeNow(_ image: CGImage, scale: CGFloat, to url: URL) -> WriteResult {
        io.sync { encodeAndWrite(image, scale: scale, to: url) }
    }

    private static func encodeAndWrite(_ image: CGImage, scale: CGFloat, to url: URL) -> WriteResult {
        guard let data = PNGWriter.data(for: image, scale: scale) else {
            Log.info("Could not encode PNG for \(url.lastPathComponent)")
            return WriteResult(data: nil, saved: false)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return WriteResult(data: data, saved: true)
        } catch {
            Log.info("Could not save \(url.path): \(error.localizedDescription)")
            return WriteResult(data: data, saved: false)
        }
    }

    /// PNG data plus the file URL, so pasting works in chat apps, Slack and Finder alike.
    static func copyToClipboard(png: Data, fileURL: URL?) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
