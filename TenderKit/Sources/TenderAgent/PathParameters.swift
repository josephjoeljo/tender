import Hummingbird
import TenderCore

extension Parameters {
    /// Hummingbird hands path parameters over still percent-encoded, and `TenderClient`
    /// encodes everything outside `A-Z a-z 0-9 - . _ ~`. Homebrew labels such as
    /// `homebrew.mxcl.postgresql@18` contain `@`, so read every name through this.
    ///
    /// Decoding lets `%2F` and `%00` through, and names end up in file paths and
    /// launchctl arguments. No service name or launchd label needs a `/`, a control
    /// character, or to be `.` or `..`, so those are refused here, before anything
    /// looks the name up. Errors are `NodeCallError`s because both the local socket and
    /// the head turn those into a 400, where an `HTTPError` would become a 500.
    public func requireDecoded(_ key: String) throws -> String {
        let raw = try require(key)
        guard let decoded = raw.removingPercentEncoding else {
            throw NodeCallError(code: "bad_request", message: "'\(key)' isn't valid percent-encoding.", httpStatus: 400)
        }
        guard !decoded.isEmpty, decoded != ".", decoded != "..",
              !decoded.unicodeScalars.contains(where: { $0 == "/" || $0.properties.generalCategory == .control }) else {
            throw NodeCallError(code: "bad_request",
                                message: "'\(key)' can't be empty, '.' or '..', or contain '/' or control characters.",
                                httpStatus: 400)
        }
        return decoded
    }
}
