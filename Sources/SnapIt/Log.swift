import Foundation
import QuartzCore

/// Appends to ~/Library/Logs/snap-it.log, the same path the old Python daemon used.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/snap-it.log")
    private static let queue = DispatchQueue(label: "snap-it.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Milliseconds since `start`, from CACurrentMediaTime.
    static func ms(since start: CFTimeInterval) -> String {
        String(format: "%.0f ms", (CACurrentMediaTime() - start) * 1000)
    }
}
