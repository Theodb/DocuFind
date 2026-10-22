// docufind-ocr: reads the text in pictures and scanned PDF pages with Apple's Vision framework.
// The search worker keeps one running and sends one JSON request per line:
//   {"kind": "image", "path": "…"}  or  {"kind": "pdf", "path": "…", "page": 3}
// Each request gets one JSON line back: {"text": "…"} or {"text": "", "error": "…"}.
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Longest side, in pixels, of what Vision reads. Enough for small print on a full page.
let maxSide: CGFloat = 2400

func recognize(_ image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { observation -> (CGRect, String)? in
        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
        return (observation.boundingBox, candidate.string)
    }
    // Reading order: top to bottom, then left to right (Vision's origin is bottom left).
    return lines.sorted { a, b in
        abs(a.0.midY - b.0.midY) > 0.01 ? a.0.midY > b.0.midY : a.0.minX < b.0.minX
    }.map(\.1).joined(separator: "\n")
}

func imageText(_ url: URL) throws -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure("This picture can't be opened.") }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxSide]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure("This picture can't be decoded.") }
    // Icons and tiny images hold no readable text.
    guard image.width >= 48, image.height >= 24 else { return "" }
    return try recognize(image)
}

func pdfPageText(_ url: URL, page number: Int) throws -> String {
    guard let document = PDFDocument(url: url) else { throw Failure("This PDF can't be opened.") }
    guard document.isLocked == false else { throw Failure("This PDF is locked with a password.") }
    guard number >= 1, number <= document.pageCount, let page = document.page(at: number - 1) else { throw Failure("This page doesn't exist.") }
    let bounds = page.bounds(for: .mediaBox)
    let scale = min(4, maxSide / max(bounds.width, bounds.height, 1))
    let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Failure("This page can't be drawn.") }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    page.draw(with: .mediaBox, to: context)
    guard let image = context.makeImage() else { throw Failure("This page can't be drawn.") }
    return try recognize(image)
}

struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

func reply(_ object: [String: String]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(10)
    FileHandle.standardOutput.write(data)
}

while let line = readLine(strippingNewline: true) {
    autoreleasepool {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = request["path"] as? String else {
            reply(["text": "", "error": "Each request needs a path."])
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            switch request["kind"] as? String {
            case "pdf": reply(["text": try pdfPageText(url, page: request["page"] as? Int ?? 1)])
            default: reply(["text": try imageText(url)])
            }
        } catch let failure as Failure {
            reply(["text": "", "error": failure.message])
        } catch {
            reply(["text": "", "error": error.localizedDescription])
        }
    }
}
