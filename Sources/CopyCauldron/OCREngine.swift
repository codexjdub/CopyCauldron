import Foundation
import Vision
import ImageIO

/// Thin wrapper around `VNRecognizeTextRequest`. Reads an image file from
/// disk, runs accurate text recognition on a `userInitiated` background
/// queue, and calls back on the main queue with the recognized text (or
/// `nil` if the request fails or yields no text).
///
/// We use this from `ClipboardMonitor` after `saveImage(...)` so a captured
/// screenshot can be found by its on-screen text via the regular search
/// filter, without blocking the capture pipeline.
enum OCREngine {
    static func recognizeText(at url: URL,
                              completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = synchronousRecognize(at: url)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func synchronousRecognize(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
