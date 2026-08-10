import Foundation

let TINE_US = "\u{1f}"
/// One level above US, which the `env` payload's alias dump already uses as its own separator.
let TINE_RS = "\u{1e}"

extension String {
    /// Strips characters the wire protocol reserves, so a value can't be mistaken for a separator.
    var socketSafe: String {
        components(separatedBy: CharacterSet(charactersIn: "\n\r;\(TINE_US)\(TINE_RS)"))
            .joined(separator: " ")
    }
}
