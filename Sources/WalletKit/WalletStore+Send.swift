import Foundation

// Sending: build + sign on-device, confirm with the real fee, broadcast — and never
// report a send the network may have accepted as a plain failure.
extension WalletStore {

    /// Build + sign (on-device) a payment WITHOUT broadcasting it, so the confirmation can
    /// show the real network fee. `isMax` carries the caller's EXPLICIT "send everything"
    /// intent (the MAX button); only then do we sweep to a single output. It is never
    /// inferred from the live balance — see the isSweep note below.
    func prepareSend(to recipient: String, amountPRL: Decimal, isMax: Bool = false) async throws -> PreparedSend {
        let recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard PRLAddress.isValid(recipient, network: network) else { throw WalletError(Loc("收款地址格式不正确")) }
        guard let mnemonic, let xp = xpub, let walletID = activeWalletID else { throw WalletError(Loc("钱包未就绪")) }
        guard unverifiedSends.isEmpty else { throw WalletError(Loc("上一笔转账是否发出尚未确认，请先查看交易记录，稍后再试")) }
        // Everything this send uses is captured now; if the wallet, network or lock state
        // changes during the network round-trips below, the send is abandoned.
        let session = chainLoadToken
        let sendNetwork = network
        let changeSets = recoverable
        guard amountPRL + Self.sendFeeReserve <= balance.available else {
            throw WalletError(Loc("余额不足：请预留至少 %@ PRL 作为手续费", "\(Self.sendFeeReserve)"))
        }
        let dir = walletDataDir
        let net = sendNetwork.rawValue
        let bb = BlockbookClient(network: sendNetwork)
        guard let amountSat = RawTx.satoshis(from: amountPRL) else {
            throw WalletError(Loc("金额无效：最多支持 %@ 位小数", "\(BlockbookClient.decimals)"))
        }
        let locked = Set(sendLocks.values.flatMap(\.keys))
        let utxos: [BlockbookClient.UTXO]
        do { utxos = try await bb.utxos(xpub: xp) } catch { throw WalletError(error.localizedDescription) }
        var utxoObjs: [[String: Any]] = []
        var inputValues: [String: Int64] = [:]
        for u in utxos where !locked.contains(u.outpoint) {
            guard let value = Int64(u.value) else {
                // A malformed UTXO value must NOT be silently zeroed — that would
                // under-fund the tx and could sweep real value into the miner fee.
                throw WalletError(Loc("链上数据异常（UTXO 金额无法解析），已取消转账以保护资金"))
            }
            utxoObjs.append(["txid": u.txid, "vout": u.vout, "value": value, "address": u.address ?? ""])
            inputValues[u.outpoint] = value
        }
        // Also offer internal-chain change UTXOs (invisible to the xpub scan) to coin
        // selection, with their address injected — oyster signs them like any other.
        for s in changeSets {
            for u in s.utxos where !locked.contains(u.outpoint) {
                guard let value = Int64(u.value) else { continue }
                utxoObjs.append(["txid": u.txid, "vout": u.vout, "value": value, "address": s.address])
                inputValues[u.outpoint] = value
            }
        }
        guard !utxoObjs.isEmpty else { throw WalletError(Loc("没有可用的 UTXO（余额不足或未确认）")) }
        let fee = (try? await bb.estimateFeePerKB()) ?? 50_000
        guard chainLoadToken == session else { throw WalletError(Loc("钱包或网络已切换，已取消本次转账")) }
        let utxosJSON = String(data: try JSONSerialization.data(withJSONObject: utxoObjs), encoding: .utf8) ?? "[]"
        // Full-balance ("MAX") send → true single-output sweep. Otherwise the fixed
        // `sendFeeReserve` (which far exceeds the real fee) would come back as a change
        // output on the internal change chain and re-strand. Same converging fold as
        // recoverChange. Partial sends keep the plain build — their change is expected,
        // and now visible + spendable via refreshChangeChain.
        //
        // CRITICAL: the sweep decision is the caller's EXPLICIT intent, never a re-read
        // of `balance.available`. That @Published value can be lowered by a concurrent
        // loadChain()/publishOverlay() during the awaits above (the xpub scan briefly
        // drops the prior tx's stranded change before refreshChangeChain restores it),
        // which would silently promote a partial send into a sweep that pays the WHOLE
        // balance to the recipient. amountSat (the user's typed amount) is what a
        // non-sweep send pays; a sweep ignores it and sends the full input set.
        let hex: String
        let paidSat: Int64
        do {
            if isMax {
                let totalInputSat = inputValues.values.reduce(Int64(0), +)
                let startSat = totalInputSat - RawTx.estimateFeeSat(inputs: utxoObjs.count, outputs: 2, feePerKB: fee)
                guard startSat > 0 else {
                    throw WalletError(Loc("余额不足：请预留至少 %@ PRL 作为手续费", "\(Self.sendFeeReserve)"))
                }
                // The user confirmed `amountPRL`. The sweep pays out everything the inputs
                // hold, which is only ever the fee reserve more than that — unless funds
                // arrived, were spent, or the wallet changed since MAX was tapped. Refuse
                // rather than send an amount the user never saw.
                guard startSat <= amountSat + Self.maxSweepSlackSat, startSat + Self.maxSweepSlackSat >= amountSat else {
                    throw WalletError(Loc("余额已变化，请重新点 MAX 后再发送"))
                }
                let sweep = try await sweepConverge(mnemonic: mnemonic, dir: dir, net: net, to: recipient,
                                                    amountSat: startSat, totalSat: totalInputSat,
                                                    feePerKB: fee, utxosJSON: utxosJSON)
                hex = sweep.hex
                paidSat = sweep.amountSat
            } else {
                hex = try await WalletDBQueue.shared.run {
                    try OysterBridge.buildSignedTx(mnemonic: mnemonic, dataDir: dir, network: net,
                                                   to: recipient, amountSat: amountSat, feeSatPerKB: fee, utxosJSON: utxosJSON)
                }
                paidSat = amountSat
            }
        } catch let e as WalletError {
            throw e
        } catch {
            throw WalletError(error.localizedDescription)
        }
        guard chainLoadToken == session else { throw WalletError(Loc("钱包或网络已切换，已取消本次转账")) }
        let raw = RawTx(hex: hex)
        var spent: [String: Int64] = [:]
        for op in raw?.outpoints ?? [] { spent[op] = inputValues[op] }
        // Fee = inputs − outputs, known exactly when every input is one we offered.
        let feeSat: Int64? = raw.flatMap { tx in
            guard spent.count == tx.inputs.count else { return nil }
            let f = spent.values.reduce(0, +) - tx.outputs.reduce(0, +)
            return f >= 0 ? f : nil
        }
        return PreparedSend(hex: hex, txid: raw?.txid, inputs: spent, recipient: recipient,
                            amount: RawTx.prl(fromSat: paidSat), fee: feeSat.map(RawTx.prl(fromSat:)),
                            isSweep: isMax, walletID: walletID, network: sendNetwork,
                            session: session, createdAt: Date())
    }

    enum SendOutcome: Equatable {
        case sent(txid: String)
        case failed(String)
        /// The broadcast request failed without a verdict: the tx may be out. Shown as
        /// pending until the indexer (or a direct lookup) settles it.
        case unverified(String)
    }

    /// Authenticate, then broadcast a tx from `prepareSend`. Never reports a send the
    /// network may have accepted as a plain failure — that invites paying twice.
    func broadcast(_ p: PreparedSend) async -> SendOutcome {
        guard chainLoadToken == p.session, network == p.network, activeWalletID == p.walletID, mnemonic != nil else {
            return .failed(Loc("钱包或网络已切换，已取消本次转账"))
        }
        guard Date().timeIntervalSince(p.createdAt) < Self.preparedSendLifetime else {
            return .failed(Loc("确认超时，请重新发送"))
        }
        // Spending requires device auth (Touch ID / password).
        guard await authenticate(reason: Loc("确认转账")) else { return .failed(Loc("认证未通过")) }
        guard chainLoadToken == p.session else { return .failed(Loc("钱包或网络已切换，已取消本次转账")) }
        guard unverifiedSends.isEmpty else { return .failed(Loc("上一笔转账是否发出尚未确认，请先查看交易记录，稍后再试")) }
        // Lock the inputs BEFORE the request goes out: a refresh racing the broadcast must
        // not offer them to another send, and a lost response must not free them.
        if let txid = p.txid { sendLocks[txid] = p.inputs }
        let bb = BlockbookClient(network: p.network)
        do {
            let txid = try await bb.broadcast(p.hex)
            if let ours = p.txid, ours != txid { releaseLock(ours, of: p) }
            recordSent(p, txid: txid, verified: true)
            return .sent(txid: txid)
        } catch {
            guard let txid = p.txid else { return .failed(error.localizedDescription) }
            let message = error.localizedDescription
            if let be = error as? BlockbookClient.BroadcastError, case .rejected(let m) = be {
                if BlockbookClient.isAlreadyKnown(m) {
                    recordSent(p, txid: txid, verified: true)
                    return .sent(txid: txid)
                }
                // The node's own verdict ("-26: …", "-25: …"): nothing was relayed.
                if m.range(of: #"^-\d+:"#, options: .regularExpression) != nil {
                    releaseLock(txid, of: p)
                    return .failed(m)
                }
            }
            // No verdict: ask whether the network has it before saying anything.
            if await bb.lookup(txid: txid) == .found {
                recordSent(p, txid: txid, verified: true)
                return .sent(txid: txid)
            }
            recordSent(p, txid: txid, verified: false)
            return .unverified(Loc("网络异常，无法确认转账是否已发出（%@）。请先查看交易记录，切勿重复发送。", message))
        }
    }

    /// Free the inputs locked for `txid` — in the live state, or in the parked state of the
    /// wallet the send came from if the user switched away mid-broadcast.
    private func releaseLock(_ txid: String, of p: PreparedSend) {
        if chainLoadToken == p.session { sendLocks[txid] = nil }
        else { parkedOverlays[overlayKey(p.walletID, p.network)]?.sendLocks[txid] = nil }
    }

    /// Reflect a broadcast send IMMEDIATELY. Blockbook can take several refreshes to index
    /// the mempool tx, so instead of blocking on a poll we overlay an optimistic 待确认 row
    /// and hold its inputs; `reconcileAfterSend` then swaps in the real indexed tx.
    private func recordSent(_ p: PreparedSend, txid: String, verified: Bool) {
        let pending = WalletTx(txid: txid, direction: .sent, amount: p.amount,
                               fee: p.fee ?? Self.sendFeeReserve, confirmations: 0,
                               time: Date(), address: p.recipient)
        guard chainLoadToken == p.session else {
            // Switched wallets while this one was broadcasting: the send still went out from
            // the original wallet, so park it with that wallet's other optimistic state.
            let key = overlayKey(p.walletID, p.network)
            var parked = parkedOverlays[key] ?? ParkedOverlay()
            parked.pendingSends[txid] = pending
            parked.sendLocks[txid] = p.inputs
            if !verified { parked.unverifiedSends.insert(txid) }
            parkedOverlays[key] = parked
            return
        }
        pendingSends[txid] = pending
        sendLocks[txid] = p.inputs
        if !verified { unverifiedSends.insert(txid) }
        publishOverlay()
        Task { await reconcileAfterSend(txid: txid) }
    }

    /// After a broadcast, pull fresh chain data a few times until Blockbook reports
    /// the new tx (which drops the optimistic overlay and makes the balance exact).
    private func reconcileAfterSend(txid: String) async {
        let session = chainLoadToken
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(3))
            guard chainLoadToken == session else { return }
            await loadChain()
            if pendingSends[txid] == nil { return }
        }
    }

    /// Pending sends the indexer still doesn't list: an unverified one after 45 s, any other
    /// after 10 min. Ask Blockbook directly — found keeps it pending (the unverified flag
    /// goes, new sends are allowed again), not found drops the row and frees its inputs.
    func resolveStalePendingSends(bb: BlockbookClient, token: UUID) async {
        let now = Date()
        let stale = pendingSends.values.filter { tx in
            now.timeIntervalSince(tx.time) > (unverifiedSends.contains(tx.txid) ? 45 : 600)
        }
        for tx in stale {
            let verdict = await bb.lookup(txid: tx.txid)
            guard chainLoadToken == token else { return }
            switch verdict {
            case .found: unverifiedSends.remove(tx.txid)
            case .notFound:
                pendingSends[tx.txid] = nil; sendLocks[tx.txid] = nil; unverifiedSends.remove(tx.txid)
            case .unknown: break
            }
        }
    }
}

/// A signed payment awaiting the user's final confirmation (see `prepareSend`).
struct PreparedSend: Identifiable {
    let id = UUID()
    let hex: String
    /// Computed locally from the signed tx (nil only if it couldn't be parsed).
    let txid: String?
    /// Inputs the tx spends (outpoint → sat).
    let inputs: [String: Int64]
    let recipient: String
    /// What the recipient receives (for MAX, the whole sweep).
    let amount: Decimal
    /// The tx's actual network fee (inputs − outputs), nil if it couldn't be worked out.
    let fee: Decimal?
    let isSweep: Bool
    fileprivate let walletID: String
    fileprivate let network: WalletNetwork
    fileprivate let session: UUID
    fileprivate let createdAt: Date

    /// Well above what a send normally costs — the confirmation says so explicitly.
    var feeIsHigh: Bool { (fee ?? 0) > WalletStore.sendFeeReserve * WalletStore.highFeeReserveMultiple }
}

/// A user-facing wallet failure (already localized).
struct WalletError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
