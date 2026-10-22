import AppKit
import LogcatCore

enum LogTextRenderer {
    static func attributed(_ text: String, palette: ThemePalette, fontSize: Double, lineBreakMode: NSLineBreakMode = .byTruncatingTail, level: LogLevel? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: level.map(palette.levelColor) ?? palette.nsText,
            .paragraphStyle: paragraph
        ])
        for token in LogSyntax.tokens(in: text) {
            result.addAttribute(.foregroundColor, value: palette.tokenColor(token.kind), range: token.range)
        }
        return result
    }

    static func details(_ text: String, palette: ThemePalette, fontSize: Double) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed(text, palette: palette, fontSize: fontSize))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }
}
