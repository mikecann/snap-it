import AppKit

/// Bold SF Pro Rounded, shared by the inline editor, hit-testing and export.
public enum TextStyle {
    public static func font(size: CGFloat) -> NSFont {
        let bold = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let rounded = bold.fontDescriptor.withDesign(.rounded) else { return bold }
        return NSFont(descriptor: rounded, size: size) ?? bold
    }

    public static func attributes(color: RGBAColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(size: fontSize), .foregroundColor: NSColor(cgColor: color.cgColor) ?? .systemPink]
    }

    /// Size of the text box. Empty text still gets one line's height so it can be clicked.
    public static func size(of text: String, fontSize: CGFloat) -> CGSize {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font(size: fontSize)])
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(max(measured.width, fontSize * 0.3)), height: ceil(measured.height))
    }
}
