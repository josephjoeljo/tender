import Hummingbird

extension Parameters {
    /// Hummingbird hands path parameters over still percent-encoded, and `TenderClient`
    /// encodes everything outside `A-Z a-z 0-9 - . _ ~`. Homebrew labels such as
    /// `homebrew.mxcl.postgresql@18` contain `@`, so read every name through this.
    public func requireDecoded(_ key: String) throws -> String {
        let raw = try require(key)
        guard let decoded = raw.removingPercentEncoding else {
            throw HTTPError(.badRequest, message: "'\(key)' isn't valid percent-encoding.")
        }
        return decoded
    }
}
