import CoreGraphics
import Foundation
import ImageIO

/// Existing images opened in the editor with `open -a "Snap It"`, the Dock icon or Finder's Open With.
public enum OpenedImage {
    /// `@2x`/`@3x` in the name wins, then the DPI (144 is 2x, 216 is 3x), else 1.
    public static func scale(fileName: String, dpi: CGFloat?) -> CGFloat {
        if let fromName = nameScale(fileName) { return fromName }
        if let dpi, dpi > 72 { return min(max((dpi / 72).rounded(), 1), 4) }
        return 1
    }

    /// Where saves go: a PNG is overwritten in place, like a fresh capture. Anything else gets a
    /// sibling PNG with the same base name (` (2)` and so on if one exists), so the original is never touched.
    public static func saveURL(for source: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        if source.pathExtension.lowercased() == "png" { return source }
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        // Keep an `@2x` suffix last, the way capture names do, so the scale survives a reopen.
        var stem = base, suffix = ""
        if let range = base.range(of: #"@[1-9]x$"#, options: .regularExpression) {
            stem = String(base[..<range.lowerBound])
            suffix = String(base[range])
        }
        var copy = 1
        while true {
            let counter = copy > 1 ? " (\(copy))" : ""
            let url = folder.appendingPathComponent("\(stem)\(counter)\(suffix).png")
            if !exists(url) { return url }
            copy += 1
        }
    }

    /// Decodes the first image in the file, upright, with its scale. Nil if it isn't an image.
    public static func load(_ url: URL) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source, fileName: url.lastPathComponent)
    }

    public static func load(data: Data, fileName: String) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source, fileName: fileName)
    }

    private static func load(_ source: CGImageSource, fileName: String) -> (image: CGImage, scale: CGFloat)? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation != 1 {
            // Photos often store rotation as metadata; bake it in so the canvas shows them upright.
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1)]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat($0.doubleValue) }
        return (image, scale(fileName: fileName, dpi: dpi))
    }

    private static func nameScale(_ fileName: String) -> CGFloat? {
        let base = (fileName as NSString).deletingPathExtension
        guard let range = base.range(of: #"@[1-9]x(?![A-Za-z0-9])"#, options: [.regularExpression, .backwards]) else { return nil }
        return CGFloat(Int(String(base[range].dropFirst().dropLast())) ?? 1)
    }
}
