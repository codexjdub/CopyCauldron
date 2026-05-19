import Foundation

struct TextPastePayload {
    let string: String
    let rtfData: Data?
    let htmlData: Data?
}

enum TextPasteTransform {
    static func payload(
        string: String,
        rtfData: Data?,
        htmlData: Data?,
        plainTextOnly: Bool
    ) -> TextPastePayload {
        TextPastePayload(
            string: plainTextOnly ? compactPlainText(string) : string,
            rtfData: plainTextOnly ? nil : rtfData,
            htmlData: plainTextOnly ? nil : htmlData
        )
    }

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
