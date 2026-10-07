import CryptoKit
import Foundation
import Security

/// Trust on first use for servers with a certificate iOS doesn't trust (self-signed, private CA).
/// Certificates iOS trusts (e.g. Let's Encrypt) are handled normally and never pinned. For the
/// others, the app shows the certificate's SHA-256 fingerprint once; if you trust it, that exact
/// certificate is accepted for that host and port from then on. Any other certificate is refused.
final class CertificateTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = CertificateTrust()

    /// One session for everything (REST, WebSocket, downloads, uploads), so the rule always applies.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: shared, delegateQueue: nil)
    }()

    private let lock = NSLock()
    private var lastRejected: [String: String] = [:]  // host:port -> fingerprint, for the prompt
    private static let pinsKey = "pinnedCertificates"

    static func hostKey(_ url: URL) -> String {
        "\(url.host() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    /// The fingerprint of the untrusted certificate this host just presented, if any.
    func rejectedFingerprint(for url: URL) -> String? {
        lock.withLock { lastRejected[Self.hostKey(url)] }
    }

    func clearRejected(for url: URL) {
        _ = lock.withLock { lastRejected.removeValue(forKey: Self.hostKey(url)) }
    }

    func pin(_ fingerprint: String, for url: URL) {
        var pins = UserDefaults.standard.dictionary(forKey: Self.pinsKey) as? [String: String] ?? [:]
        pins[Self.hostKey(url)] = fingerprint
        UserDefaults.standard.set(pins, forKey: Self.pinsKey)
    }

    private func pinned(_ key: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.pinsKey) as? [String: String])?[key]
    }

    /// "AB:CD:…" SHA-256 of the certificate as the server sent it.
    static func fingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)  // trusted by iOS: nothing to pin
            return
        }
        let key = "\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"
        guard let fp = Self.fingerprint(trust) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if pinned(key) == fp {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.withLock { lastRejected[key] = fp }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
