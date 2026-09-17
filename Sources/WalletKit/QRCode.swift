import SwiftUI
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum QRCode {
    static func cgImage(from string: String) -> CGImage? {
        let ctx = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return ctx.createCGImage(out, from: out.extent)
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
