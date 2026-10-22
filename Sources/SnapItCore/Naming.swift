import Foundation
import CoreGraphics

/// macOS-style screenshot names: `Screenshot 2026-10-22 at 12.47.51 PM@2x.png`.
public enum ScreenshotNaming {
    public static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return "Screenshot \(formatter.string(from: date))"
    }

    /// `@2x`, `@3x` for whole-number scales above 1, otherwise nothing.
    public static func scaleSuffix(_ scale: CGFloat) -> String {
        let rounded = scale.rounded()
        guard rounded >= 2, abs(scale - rounded) < 0.01 else { return "" }
        return "@\(Int(rounded))x"
    }

    public static func fileName(date: Date, scale: CGFloat, copy: Int = 1, timeZone: TimeZone = .current) -> String {
        let counter = copy > 1 ? " (\(copy))" : ""
        return "\(baseName(for: date, timeZone: timeZone))\(counter)\(scaleSuffix(scale)).png"
    }

    public static func uniqueURL(in folder: URL, date: Date, scale: CGFloat, timeZone: TimeZone = .current,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var copy = 1
        while true {
            let url = folder.appendingPathComponent(fileName(date: date, scale: scale, copy: copy, timeZone: timeZone))
            if !exists(url) { return url }
            copy += 1
        }
    }
}
