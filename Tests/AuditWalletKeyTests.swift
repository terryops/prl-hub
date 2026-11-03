import Foundation
import Testing
@testable import Pearl

/// Wallet auth races from the 2026-10-27 Android audit (W01–W05), iOS side. Each test uses its
/// own throwaway `WalletStore` (not `.shared`) and a fake auth prompt: no keychain item, wallet
/// list or real wallet db is read or written.
@MainActor
struct AuditWalletKeyTests {
    /// BIP39 test vector — a public seed, only ever pointed at a temporary directory.
    private static let testPhrase = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"

    private static func scratchDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audit-wallet-\(UUID().uuidString)", isDirectory: true)
    }

    /// W05: the wallet changing (switch / lock / removal) while the recovery prompt is up must
    /// cancel the sweep, not apply the old authorisation to the wallet opened since.
    /// Before the fix the session was captured after the prompt, so this went on to the
    /// destination check ("收款地址格式不正确") instead.
    @Test func recoveryAuthorisedAfterTheWalletChangedIsCancelled() async {
        let store = WalletStore()
        store.authenticateOverride = { _ in
            store.chainLoadToken = UUID()   // what select / lock / removeWallet do meanwhile
            return true
        }
        let r = await store.recoverChange(to: "not-an-address")
        #expect(!r.ok)
        #expect(r.message == Loc("钱包或网络已切换，已取消本次找回"))
    }

    /// The prompt being refused still ends the request with the usual message (W02: every exit
    /// of the prompt releases the caller).
    @Test func refusedRecoveryPromptEndsTheRequest() async {
        let store = WalletStore()
        store.authenticateOverride = { _ in false }
        let r = await store.recoverChange(to: "not-an-address")
        #expect(!r.ok)
        #expect(r.message == Loc("认证未通过"))
    }

    /// W05: a MAX send / recovery sweep that outlives a wallet removal must not start another
    /// build — removal queues the wallet db for deletion, and a later build re-creates it.
    @Test func sweepBuildsNothingOnceTheSessionIsRetired() async {
        let store = WalletStore()
        let dir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await store.sweepConverge(mnemonic: Self.testPhrase, dir: dir.path, net: WalletNetwork.testnet.rawValue,
                                              to: "unused", amountSat: 50_000, totalSat: 100_000, feePerKB: 1_000,
                                              utxosJSON: "[]", session: UUID(), cancelled: "cancelled")
            Issue.record("a retired session still built a tx")
        } catch {
            #expect((error as? WalletError)?.message == "cancelled")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))   // oyster never opened a db there
    }

    /// The guard must not get in the way of the live session: the build runs (and here fails on
    /// its own terms — there are no inputs), rather than being reported as cancelled.
    @Test func sweepForTheLiveSessionStillBuilds() async {
        let store = WalletStore()
        let dir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await store.sweepConverge(mnemonic: Self.testPhrase, dir: dir.path, net: WalletNetwork.testnet.rawValue,
                                              to: "unused", amountSat: 50_000, totalSat: 100_000, feePerKB: 1_000,
                                              utxosJSON: "[]", session: store.chainLoadToken, cancelled: "cancelled")
        } catch {
            #expect((error as? WalletError)?.message != "cancelled")
        }
    }
}
