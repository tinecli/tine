import Foundation

let TINE_US = "\u{1f}"
/// Splits the sections of a multi-part payload (the `env` buffer), one level
/// above US — which the alias dump already uses as its own line separator.
let TINE_RS = "\u{1e}"

extension String {
    /// Safe to put in a socket reply: the shell reads one line of `;`-joined
    /// fields, so an error message must not carry either separator.
    var socketSafe: String {
        components(separatedBy: CharacterSet(charactersIn: "\n\r;\(TINE_US)\(TINE_RS)"))
            .joined(separator: " ")
    }
}
