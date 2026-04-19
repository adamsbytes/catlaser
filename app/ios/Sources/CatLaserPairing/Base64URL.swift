import Foundation

/// Decode a base64url-no-pad ASCII string into raw bytes.
///
/// The coordination server emits the device's Ed25519 public key in
/// this encoding (see the Python `DeviceIdentity._base64url_nopad`
/// helper). Standard `Data(base64Encoded:)` rejects `-` / `_` and
/// insists on padding, so a small transform converts to standard
/// base64 before handing off to Foundation's decoder. Returns `nil`
/// on any malformed input — the caller treats this as a protocol
/// violation at the pairing boundary.
func decodeBase64URLNoPad(_ value: String) -> Data? {
    var standard = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = standard.utf8.count % 4
    if remainder != 0 {
        standard.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: standard)
}
