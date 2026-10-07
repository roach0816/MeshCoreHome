import Foundation
import Network
import Observation

/// Finds MeshHome servers on the local network. A native install with LAN discovery on advertises
/// "_meshhome._tcp" (avahi) with a TXT record "url" holding the address to open.
@MainActor @Observable
final class ServerBrowser {
    struct Server: Identifiable, Hashable {
        let name: String
        let url: String
        var id: String { url }
    }

    private(set) var servers: [Server] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_meshhome._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.server(from:))
            Task { @MainActor in
                self?.servers = Array(Set(found)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    nonisolated private static func server(from result: NWBrowser.Result) -> Server? {
        guard case let .service(name, _, _, _) = result.endpoint,
              case let .bonjour(txt) = result.metadata,
              let url = txt["url"], let parsed = URL(string: url),
              parsed.scheme == "https" || parsed.scheme == "http", parsed.host() != nil
        else { return nil }
        return Server(name: name, url: url)
    }
}
