import Foundation

// Stranded change: the internal-chain change addresses the xpub scan can't see —
// discovered by trial-signing, folded into balance and coin selection, recoverable.
extension WalletStore {

    /// Force a fresh internal-chain discovery (the explicit recovery screen). `loadChain`
    /// already keeps `recoverable`/`changeBalance` current; this re-runs the full scan,
    /// through the same single-flight load so it can't race a refresh.
    func scanRecoverableChange() async {
        guard xpub != nil else { return }
        recoveryScanning = true
        defer { recoveryScanning = false }
        await loadChain(forceChangeScan: true)
    }

    /// `work` over `items` with at most `limit` requests in flight; results in input order.
    private nonisolated static func fetchAll<R: Sendable>(_ items: [String], limit: Int = 6,
                                                          _ work: @escaping @Sendable (String) async -> R) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            while next < min(limit, items.count) {
                let i = next; next += 1
                group.addTask { (i, await work(items[i])) }
            }
            while let (i, r) = await group.next() {
                results[i] = r
                if next < items.count {
                    let j = next; next += 1
                    group.addTask { (j, await work(items[j])) }
                }
            }
            return results.compactMap { $0 }
        }
    }

    /// Track the wallet's internal-chain change addresses (which the xpub scan can't
    /// see), fold their balance into `changeBalance` and their UTXOs into `recoverable`
    /// for both display and coin selection — so change stops stranding. The expensive
    /// discovery (history + trial-signing to confirm ownership) only runs when the set of
    /// confirmed sends changed, or `force`; the per-address refresh runs every time but
    /// only for change still worth watching (spent-out addresses are retired).
    func refreshChangeChain(xpub xp: String, dir: String, net: String, token: UUID, force: Bool) async {
        guard let mnemonic else { return }
        let scanNetwork = network
        let bb = BlockbookClient(network: scanNetwork)
        func current() -> Bool { isCurrentChainLoad(token, mnemonic: mnemonic, network: scanNetwork) }
        // A send funded ENTIRELY by internal-chain change touches no xpub-derived
        // address, so the xpub history can never report it: its optimistic 待确认
        // row never reconciled (stuck "Unconfirmed" forever, even once mined) and
        // its outflow stayed deducted on top of the already-shrunk changeBalance.
        // Each owned change address's OWN history is the only place those spends
        // exist — fold the txs the xpub scan missed into the snapshot (so they
        // reconcile, show live confirmations, and survive relaunch), and surface
        // their outputs as change candidates (their change is invisible to
        // changeCandidates' xpub scan for the same reason).
        let watched = Array(force ? change.owned : change.active).sorted()
        let mine = change.owned.union(xpubAddresses)
        let histories = await Self.fetchAll(watched) { addr in try? await bb.history(address: addr, mine: mine) }
        guard current() else { return }
        var changeChainOuts: [String] = []
        var outsByAddress: [String: [String]] = [:]
        var spendsByAddress: [String: [WalletTx]] = [:]
        for (addr, r) in zip(watched, histories) {
            guard let r else { continue }
            spendsByAddress[addr] = r.txs
            outsByAddress[addr] = r.outAddrs
            for a in r.outAddrs where !changeChainOuts.contains(a) { changeChainOuts.append(a) }
            // Xpub-history copies stay authoritative (token-aware classification);
            // previously-merged copies are REPLACED so confirmations stay live.
            // NOTE: a merged tx's "sent" amount counts its own not-yet-classified
            // change as paid out; once the oracle below tags that change ours, the
            // next load remaps with the bigger `mine` set and the amount corrects.
            let xpubTxids = Set(serverTxs.map { $0.txid }).subtracting(mergedChangeTxids)
            let fresh = r.txs.filter { !xpubTxids.contains($0.txid) }
            guard !fresh.isEmpty else { continue }
            let freshIds = Set(fresh.map { $0.txid })
            mergedChangeTxids.formUnion(freshIds)
            serverTxs = (serverTxs.filter { !freshIds.contains($0.txid) } + fresh)
                .sorted { $0.time > $1.time }
            // The indexer reports these txids → same reconciliation as the xpub history.
            settleIndexed(freshIds)
        }
        // NOTE: do NOT publishOverlay() here. Dropping the optimistic pending row above
        // while `changeBalance` still holds its stale pre-send value would briefly
        // republish the balance at the FULL pre-send amount (base = serverBalance +
        // stale change, with the overlay now gone) — a visible spike back to "as if the
        // send never happened", and an overstated `available` the send guard could act
        // on. changeBalance is recomputed from live UTXOs below, and the publishOverlay()
        // at the end of this function publishes the correct, deducted figure.
        let scanSig = Self.changeScanSignature(serverTxs)
        if force || scanSig != lastChangeScanSig {
            // Incremental: only blocks from the watermark on (a forced scan reads everything).
            let from = force ? nil : change.scanHeight.map { max(0, $0 - Self.changeScanReorgMargin) }
            if let scan = try? await bb.changeCandidates(xpub: xp, fromHeight: from, extra: changeChainOuts) {
                guard current() else { return }
                // Filter FIRST, then cap: already-classified addresses must not use up the batch.
                let todo = scan.candidates.filter {
                    !change.owned.contains($0.address) && !change.foreign.contains($0.address) && !change.empty.contains($0.address)
                }
                let batch = Array(todo.prefix(Self.changeScanBatch))
                let fetched = await Self.fetchAll(batch.map(\.address)) { addr in try? await bb.utxos(address: addr) }
                guard current() else { return }
                var complete = todo.count <= batch.count
                let oracleFee = Self.oracleFeePerKB
                for (candidate, utxos) in zip(batch, fetched) {
                    let addr = candidate.address
                    // A failed lookup is not "empty": leave it for the next pass.
                    guard let utxos else { complete = false; continue }
                    let valueSat = utxos.compactMap { Int64($0.value) }.reduce(0, +)
                    guard !utxos.isEmpty, valueSat > 0 else {
                        // Spent already. Final once its creating tx is confirmed; unconfirmed
                        // change simply isn't spendable (listed) yet and gets another look.
                        if candidate.confirmed { change.empty.insert(addr) }
                        continue
                    }
                    let json = Self.encodeUTXOs(utxos, address: addr)
                    // Ownership oracle: oyster signs only its own keys, so a successful build
                    // proves the address is ours (a foreign recipient throws). Never broadcast.
                    //
                    // Trial-sign as a single-output sweep at the relay-floor fee, reserving a
                    // 2-output fee so the build always has headroom. The old test (½-value
                    // output at 50k sat/kB) FAILED for small owned change — the fee exceeded
                    // the value — and mis-cached it as foreign, hiding those funds permanently.
                    let trialFee = RawTx.estimateFeeSat(inputs: utxos.count, outputs: 2, feePerKB: oracleFee)
                    let trialAmount = max(Int64(1), valueSat - trialFee)
                    let owned = await WalletDBQueue.shared.run { () -> Bool in
                        (try? OysterBridge.buildSignedTx(mnemonic: mnemonic, dataDir: dir, network: net,
                            to: addr, amountSat: trialAmount, feeSatPerKB: oracleFee, utxosJSON: json)) != nil
                    }
                    // A wallet/network switch mid-scan cleared these sets; don't write them under the new wallet's keys.
                    guard current() else { return }
                    if owned { change.owned.insert(addr) } else { change.foreign.insert(addr) }
                }
                // Only a complete pass may move the watermark / signature on — otherwise the
                // next load picks up where this one stopped.
                if complete {
                    lastChangeScanSig = scanSig
                    if let h = scan.maxHeight { change.scanHeight = max(change.scanHeight ?? h, h) }
                    if force { changeScanForced = false }
                }
                change.save(prefix: changeKeyPrefix, network: scanNetwork)
            }
        }
        let owned = Array(force ? change.owned : change.active).sorted()
        let utxoSets = await Self.fetchAll(owned) { addr in try? await bb.utxos(address: addr) }
        guard current() else { return }
        // One failed lookup would under-report the change balance (and cache it for the next
        // launch). Keep the last good figures instead; the next load tries again.
        guard !utxoSets.contains(where: { $0 == nil }) else { return }
        var allChangeSat: Int64 = 0           // EVERY owned change UTXO → the balance TOTAL (stable mid-sweep)
        var spendableChangeSat: Int64 = 0     // excludes in-flight-swept → the balance AVAILABLE (matches selection)
        var sets: [RecoverableUTXOSet] = []   // offered to recover + coin selection (excludes in-flight-swept)
        let classified = change.owned.union(change.foreign).union(change.empty)
        for (addr, maybeUTXOs) in zip(owned, utxoSets) {
            let utxos = maybeUTXOs ?? []
            if utxos.isEmpty {
                // Retire fully spent change: nothing left on it, every spend of it merged and
                // deep enough not to reorg away, and every output of those spends classified —
                // there is nothing more to learn from re-fetching it on every load.
                if let spends = spendsByAddress[addr], !spends.isEmpty,
                   spends.allSatisfy({ $0.confirmations >= Self.changeRetireDepth }),
                   (outsByAddress[addr] ?? []).allSatisfy(classified.contains) {
                    change.retired.insert(addr)
                    let archived = Set(change.archive.map(\.txid))
                    change.archive += spends.filter { mergedChangeTxids.contains($0.txid) && !archived.contains($0.txid) }
                }
                continue
            }
            change.retired.remove(addr)
            allChangeSat += utxos.compactMap { Int64($0.value) }.reduce(0, +)
            // Filtered against the in-flight recovery as it stands NOW, after the awaits: a
            // sweep broadcast while these requests were out must not be re-offered.
            let spendable = recoveringOutpoints.isEmpty ? utxos
                : utxos.filter { !recoveringOutpoints.contains($0.outpoint) }
            let valueSat = spendable.compactMap { Int64($0.value) }.reduce(0, +)
            guard !spendable.isEmpty, valueSat > 0 else { continue }
            spendableChangeSat += valueSat
            sets.append(RecoverableUTXOSet(address: addr, utxos: spendable, valueSat: valueSat))
        }
        // total counts in-flight-swept change so the displayed total holds steady mid-sweep;
        // available excludes it, because coin selection can't spend an outpoint already
        // committed to a recovery sweep — otherwise a send could be offered phantom funds.
        changeBalance = WalletBalance(total: RawTx.prl(fromSat: allChangeSat),
                                      available: RawTx.prl(fromSat: spendableChangeSat))
        // Cache the scanned change balance so the next launch can fold it into the very
        // first publish — without this the hero briefly shows only the xpub (external)
        // balance, then "jumps up" seconds later when this slow scan completes.
        change.balance = changeBalance
        change.save(prefix: changeKeyPrefix, network: scanNetwork)
        let nextSets = sets.sorted { $0.valueSat > $1.valueSat }
        if nextSets != recoverable { recoverable = nextSets }
        if !recoveryScanned { recoveryScanned = true }
        publishOverlay()
    }

    func loadChangeClassification(for net: WalletNetwork) {
        change = ChangeChainCache.load(prefix: changeKeyPrefix, network: net)
        // Seed the change balance from the last scan so the first publish already
        // includes it (no 48→52 jump at launch); refreshChangeChain re-verifies and
        // overwrites it with live data shortly after.
        if let cached = change.balance { changeBalance = cached }
        lastChangeScanSig = nil
    }

    /// Signature of the CONFIRMED sends in the latest history, used to decide when to
    /// re-run change discovery: only our own sends create change, and their change is
    /// only listable once they confirm — so a send re-triggers discovery when it confirms.
    private static func changeScanSignature(_ txs: [WalletTx]) -> String {
        txs.filter { $0.direction == .sent && $0.confirmations >= 1 }.map(\.txid).sorted().joined(separator: ",")
    }

    /// Sweep every rediscovered stranded-change UTXO to `destination` in one tx,
    /// folding any residual change back in so nothing re-strands. Requires device auth.
    func recoverChange(to destination: String) async -> (ok: Bool, message: String) {
        guard await authenticate(reason: Loc("确认找回搁浅的找零")) else { return (false, Loc("认证未通过")) }
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard PRLAddress.isValid(destination, network: network) else { return (false, Loc("收款地址格式不正确")) }
        guard let mnemonic else { return (false, Loc("钱包未就绪")) }
        let session = chainLoadToken
        // Change already committed to a pending send can't be swept again.
        let locked = Set(sendLocks.values.flatMap(\.keys))
        let sets = recoverable.compactMap { s -> RecoverableUTXOSet? in
            let utxos = s.utxos.filter { !locked.contains($0.outpoint) }
            let value = utxos.compactMap { Int64($0.value) }.reduce(0, +)
            return utxos.isEmpty || value <= 0 ? nil : RecoverableUTXOSet(address: s.address, utxos: utxos, valueSat: value)
        }
        let total = sets.reduce(Int64(0)) { $0 + $1.valueSat }
        guard !sets.isEmpty, total > 0 else { return (false, Loc("没有可找回的找零")) }
        let dir = walletDataDir
        let net = network.rawValue
        let bb = BlockbookClient(network: network)
        let feePerKB = (try? await bb.estimateFeePerKB()) ?? 50_000
        guard chainLoadToken == session else { return (false, Loc("钱包或网络已切换，已取消本次找回")) }
        let utxosJSON = Self.encodeUTXOs(sets)
        let inputCount = sets.reduce(0) { $0 + $1.utxos.count }
        let hex: String
        do {
            // Over-reserve (2 outputs' worth of fee) so the first build succeeds with a
            // change output, then fold that change back in until the sweep collapses to a
            // single output — no residual re-stranding.
            let startSat = total - RawTx.estimateFeeSat(inputs: inputCount, outputs: 2, feePerKB: feePerKB)
            guard startSat > 0 else { return (false, Loc("找零金额过小，不足以支付手续费")) }
            hex = try await sweepConverge(mnemonic: mnemonic, dir: dir, net: net, to: destination,
                                          amountSat: startSat, totalSat: total,
                                          feePerKB: feePerKB, utxosJSON: utxosJSON).hex
        } catch {
            return (false, error.localizedDescription)
        }
        let txid: String
        do {
            txid = try await bb.broadcast(hex)
        } catch {
            // A lost response isn't a failed sweep: settle it before reporting.
            guard let ours = RawTx(hex: hex)?.txid, await bb.lookup(txid: ours) == .found else {
                return (false, error.localizedDescription)
            }
            txid = ours
        }
        guard chainLoadToken == session else { return (true, txid) }
        // Guard the just-swept outpoints so a refresh/re-scan before Blockbook indexes the
        // spend can't re-discover them and flip the screen back to "un-recovered". They stay
        // in `changeBalance`, so the total holds steady until the funds land on the destination.
        recoveringOutpoints = Set(sets.flatMap { s in s.utxos.map(\.outpoint) })
        recoveringTxid = txid
        recoverable = []
        recoveryScanned = false
        // Refresh a few times so the recovered funds show up once Blockbook indexes them.
        Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(3))
                await self?.loadChain()
            }
        }
        return (true, txid)
    }

    /// Converging single-output sweep: starting from `amountSat`, rebuild the tx while
    /// folding any residual change back into the payment until it collapses to one
    /// output — so a full-balance send/recovery leaves nothing on the internal change
    /// chain. Shared by `prepareSend()` (MAX) and `recoverChange()`. Returns the signed tx
    /// and what it pays the destination.
    func sweepConverge(mnemonic: String, dir: String, net: String, to destination: String,
                               amountSat: Int64, totalSat: Int64, feePerKB: Int64,
                               utxosJSON: String) async throws -> (hex: String, amountSat: Int64) {
        var amountSat = amountSat
        var hex = ""
        for _ in 0..<5 {
            let payment = amountSat
            hex = try await WalletDBQueue.shared.run {
                try OysterBridge.buildSignedTx(mnemonic: mnemonic, dataDir: dir, network: net,
                                               to: destination, amountSat: payment, feeSatPerKB: feePerKB, utxosJSON: utxosJSON)
            }
            let outs = Self.txOutputValues(hex)
            guard outs.count > 1 else { break }                  // single output → clean sweep
            let change = outs.reduce(Int64(0), +) - amountSat     // payment is exactly amountSat
            guard change > 0, amountSat + change < totalSat else { break }
            amountSat += change
        }
        return (hex, amountSat)
    }

    private static func encodeUTXOs(_ utxos: [BlockbookClient.UTXO], address: String) -> String {
        encodeUTXOs(utxos.map { (txid: $0.txid, vout: $0.vout, value: $0.value, address: address) })
    }
    private static func encodeUTXOs(_ sets: [RecoverableUTXOSet]) -> String {
        encodeUTXOs(sets.flatMap { s in s.utxos.map { (txid: $0.txid, vout: $0.vout, value: $0.value, address: s.address) } })
    }
    private static func encodeUTXOs(_ items: [(txid: String, vout: Int, value: String, address: String)]) -> String {
        var objs: [[String: Any]] = []
        for it in items {
            guard let v = Int64(it.value) else { continue }
            objs.append(["txid": it.txid, "vout": it.vout, "value": v, "address": it.address])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objs),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Output values (sat) of a raw signed tx — used to detect and measure a change
    /// output while converging the sweep. Empty when the hex can't be parsed.
    nonisolated static func txOutputValues(_ hex: String) -> [Int64] {
        RawTx(hex: hex)?.outputs ?? []
    }
}

/// A set of stranded-change UTXOs sitting on one address the xpub scan can't see,
/// confirmed spendable by us (oyster could sign a trial tx for it).
struct RecoverableUTXOSet: Identifiable, Equatable {
    let address: String
    let utxos: [BlockbookClient.UTXO]
    let valueSat: Int64
    var id: String { address }
    var valuePRL: Decimal { RawTx.prl(fromSat: valueSat) }
}
