import XCTest
@testable import MeshHome

/// Backup download and restore upload against a real server (skipped without MESHHOME_TEST_SERVER).
final class RestoreRoundTripTests: XCTestCase {
    func testBackupDownloadUploadAndInspect() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["MESHHOME_TEST_SERVER"], let password = env["MESHHOME_TEST_PASSWORD"] else {
            throw XCTSkip("no test server")
        }
        let base = URL(string: "http://\(server)")!
        let signedIn = try await APIClient(base: base).signIn(username: env["MESHHOME_TEST_USER"] ?? "owner", password: password, deviceName: "restore test")
        let api = APIClient(base: base, token: signedIn.token)
        defer { Task { try? await api.signOut() } }

        let created = try await api.createBackup(passphrase: "restore-test-passphrase")
        let file = try await api.download("/api/backups/\(created.name)", as: created.name)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0, 100)

        let progress = Progress()
        let id = try await api.uploadBackup(file) { p in progress.completedUnitCount = Int64(p * 100) }
        let summary = try await api.inspectRestore(id, passphrase: "restore-test-passphrase")
        XCTAssertTrue(summary.canRestore, "\(summary.errors)")
        do {
            _ = try await api.inspectRestore(id, passphrase: "wrong passphrase!!")
            XCTFail("a wrong passphrase was accepted")
        } catch let e as APIError {
            XCTAssertTrue(e.message.lowercased().contains("passphrase"), e.message)
        }
        try await api.deleteBackup(created.name)
    }
}
