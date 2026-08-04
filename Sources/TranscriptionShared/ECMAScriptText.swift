import Foundation

public enum ECMAScriptText {
    private static let trimCharacters = CharacterSet(
        charactersIn: "\u{0009}\u{000B}\u{000C}\u{0020}\u{00A0}\u{1680}"
            + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}"
            + "\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}"
            + "\u{FEFF}\u{000A}\u{000D}\u{2028}\u{2029}"
    )

    /// Matches JavaScript `String.trim()` without removing Foundation's extra
    /// whitespace characters, such as U+0085.
    public static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: trimCharacters)
    }
}
