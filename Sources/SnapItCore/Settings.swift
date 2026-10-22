import Foundation

/// Everything Snap It remembers, in UserDefaults. There is no settings window.
public struct SnapItSettings {
    private let defaults: UserDefaults
    private let home: URL

    public init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
    }

    public var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: "saveFolder"), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
            return home.appendingPathComponent("Screenshots", isDirectory: true)
        }
        nonmutating set { defaults.set(newValue.path, forKey: "saveFolder") }
    }

    /// The last drawing tool. Crop is a one-off, so it is never remembered.
    public var lastTool: Tool {
        get { defaults.string(forKey: "lastTool").flatMap(Tool.init(rawValue:)).flatMap { $0 == .crop ? nil : $0 } ?? .arrow }
        nonmutating set { if newValue != .crop { defaults.set(newValue.rawValue, forKey: "lastTool") } }
    }

    public var color: RGBAColor {
        get {
            guard let c = defaults.array(forKey: "color") as? [Double], c.count == 4 else { return .hotPink }
            return RGBAColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
        }
        nonmutating set { defaults.set([newValue.red, newValue.green, newValue.blue, newValue.alpha].map(Double.init), forKey: "color") }
    }

    public var thickness: CGFloat {
        get { defaults.object(forKey: "thickness") as? Double ?? 7 }
        nonmutating set { defaults.set(Double(newValue), forKey: "thickness") }
    }

    public var textSize: CGFloat {
        get { defaults.object(forKey: "textSize") as? Double ?? 35 }
        nonmutating set { defaults.set(Double(newValue), forKey: "textSize") }
    }
}
