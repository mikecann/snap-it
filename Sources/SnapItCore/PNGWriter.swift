import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNGWriter {
    /// PNG data with DPI set to 72 × scale, so apps show a 2x capture at its point size.
    public static func data(for image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
