import CoreImage
import Foundation

/// Renders a pairing payload as a QR code (error correction M). The payload is
/// encoded verbatim: leo built it, so the app never reshapes it.
enum LeoQRCode {
    /// Quiet zone around the code, in modules (the QR spec asks for four).
    private static let quietZoneModules: CGFloat = 4

    /// A square image at least `side` pixels wide: whole pixels per module so
    /// the edges stay sharp, dark modules on a white field, which readers need
    /// in dark mode too. nil for an empty payload.
    static func image(for payload: String, side: CGFloat) -> CGImage? {
        guard !payload.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }

        let modules = code.extent.width + 2 * quietZoneModules
        let scale = max(1, (side / modules).rounded(.up))
        let total = CGRect(x: 0, y: 0, width: modules * scale, height: modules * scale)
        let scaled = code.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: quietZoneModules * scale, y: quietZoneModules * scale))
        let field = CIImage(color: .white).cropped(to: total)
        return CIContext().createCGImage(scaled.composited(over: field), from: total)
    }
}
