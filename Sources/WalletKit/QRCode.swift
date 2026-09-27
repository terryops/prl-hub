import SwiftUI
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
enum QRCode {
    /// One context for the app's lifetime — creating a CIContext is expensive, and the
    /// 收款 screen asks for its code on every render.
    private static let context = CIContext()
    /// The last few rendered codes (receive addresses), so re-renders are free.
    private static var cache: [String: CGImage] = [:]

    static func cgImage(from string: String) -> CGImage? {
        if let hit = cache[string] { return hit }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = context.createCGImage(out, from: out.extent) else { return nil }
        if cache.count >= 16 { cache.removeAll() }
        cache[string] = image
        return image
    }
}

func copyToPasteboard(_ s: String) {
    #if os(iOS)
    UIPasteboard.general.string = s
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #endif
}
