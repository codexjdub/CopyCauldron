import Foundation

enum TextPasteTransform {
    static func compactPlainText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        var blankRun = 0

        for lineSlice in lines {
            let line = String(lineSlice)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blankRun += 1
                if blankRun == 1 {
                    output.append("")
                }
            } else {
                blankRun = 0
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }
}
