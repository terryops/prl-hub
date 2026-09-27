import SwiftUI
import Combine

/// A withdrawal POST whose outcome is unknown (timeout, 5xx, unreadable reply).
/// Submitting stays locked until the history shows a new withdrawal or, after a few
/// clean looks, provably doesn't — a blind re-submit could send the money twice
/// (address-book withdrawals need no e-mail code, so nothing else would stop it).
struct PendingWithdrawCheck: Equatable {
    let knownIDs: Set<Int>
    /// `knownIDs` came from a history read made just before the POST; without one,
    /// "no new row" can't prove anything.
    let knownComplete: Bool

    /// Any withdrawal that wasn't there before. Deliberately loose (no amount /
    /// address match — the list's amount semantics are unverified): mistaking another
    /// new withdrawal for this one only blocks a re-submit, never causes one.
    func isNew(_ w: STWithdraw) -> Bool { !knownIDs.contains(w.id) }
}

/// SafeTrade → on-chain withdrawal of PRL or USDT, per SafeTrade's REST API
/// (swagger: /api/v2/trade/public/swagger.json, checked 2026-09-23):
///   1. POST /trade/account/withdraws/generate_code {type:"email", address, currency, amount, blockchain_key}
///      → SafeTrade e-mails a 6-digit code bound to that address + amount
///   2. POST /trade/account/withdraws {currency, amount, address, blockchain_key,
///      email_code, otp_code (2FA on), phone_code (phone verified)}
///   Or, to a SafeTrade address-book entry: {currency, amount, blockchain_key,
///   beneficiary_id, otp_code, phone_code} — no address, no e-mail code.
@MainActor
final class WithdrawStore: ObservableObject {
    let currency: String                     // "prl" | "usdt"
    /// Holds the per-currency unverified-withdrawal lock (outlives this sheet).
    private let trade: SafeTradeStore
    /// Every chain the exchange lists for this currency (open or not).
    @Published var networks: [STCurrencyNetwork] = []
    /// Decimal places the exchange accepts for this currency (PRL 8, USDT 6).
    @Published var precision = 8
    /// The chosen chain. PRL has one and it is picked automatically; USDT has
    /// several and the user must pick — a wrong chain can lose the funds.
    @Published var networkKey: String?
    var network: STCurrencyNetwork? { networks.first { $0.blockchain_key == networkKey } }
    var openNetworks: [STCurrencyNetwork] { networks.filter(\.canWithdraw) }
    @Published var history: [STWithdraw] = []
    /// `history` holds a successful read (not just the empty initial value).
    private var historyLoaded = false
    /// SafeTrade address-book entries for this currency (active and pending).
    @Published var beneficiaries: [STBeneficiary] = []
    /// Why the SafeTrade address book shows nothing usable here (read failed, or it
    /// has entries but none for this coin/chain) — nil when it's fine or empty.
    @Published var bookNote: String?
    /// Set when the currency info (chains, fee, minimum) couldn't be loaded —
    /// without it nothing can be submitted, so the page must say why.
    @Published var loadError: String?
    @Published var loadingInfo = false
    /// "email" / "phone" while that code is being requested.
    @Published var sendingCode: String?
    /// Seconds until each code's "获取验证码" can be tapped again, per code type.
    @Published var cooldowns: [String: Int] = [:]
    /// Address | amount | chain the sent codes were issued for. SafeTrade binds a
    /// code to exactly these, so once the form drifts from it the codes are dead.
    @Published var codeContext: String?
    @Published var submitting = false
    @Published var needsPhoneCode = false    // revealed when the exchange asks for an SMS code
    @Published var error: String?
    @Published var notice: String?
    /// The key was refused for this network's IP — see UntrustedIPCard.
    @Published var ipIssue: SafeTradeIPIssue?
    @Published private(set) var verifying = false

    private let client = SafeTradeClient()

    init(currency: String, trade: SafeTradeStore) {
        self.currency = currency
        self.trade = trade
    }

    /// The unverified withdrawal of this currency, if any.
    var unverified: PendingWithdrawCheck? { trade.unverifiedWithdraws[currency] }

    func load() async {
        loadingInfo = true
        async let c = client.currency(currency)
        async let h = client.withdraws(currency: currency)
        async let b = client.beneficiaries()
        do {
            let cc = try await c
            networks = cc.networks
            precision = cc.precision ?? precision
            if cc.networks.count == 1 { networkKey = cc.networks[0].blockchain_key }
            loadError = cc.networks.isEmpty ? Loc("SafeTrade 没有返回 %@ 的提现网络", currency.uppercased()) : nil
        } catch {
            loadError = Loc("读取 SafeTrade 提现信息失败：%@", error.localizedDescription)
        }
        loadingInfo = false
        // History and the address book are optional extras — a failure there just
        // leaves them out (or as they were) rather than blocking the withdrawal itself.
        if let hh = try? await h { history = hh; historyLoaded = true }
        do {
            let all = try await b
            // An entry without a currency id still belongs here if its chain is one of ours.
            beneficiaries = all.filter {
                $0.currencyID == currency || ($0.currencyID == nil && network(forKey: $0.blockchain_key) != nil)
            }
            let usable = beneficiaries.filter { $0.destination != nil && network(forKey: chainKey(of: $0)) != nil }
            if !all.isEmpty && usable.isEmpty {
                let kinds = all.prefix(6).map { "\($0.currencyID ?? "?")/\($0.blockchain_key ?? "?")" }
                bookNote = Loc("SafeTrade 地址簿有 %d 个地址（%@），但没有可用于 %@ 的。",
                               all.count, kinds.joined(separator: ", "), currency.uppercased())
            } else {
                bookNote = nil
            }
        } catch {
            beneficiaries = []
            bookNote = Loc("读取 SafeTrade 地址簿失败：%@", error.localizedDescription)
        }
        // Re-opened with an outcome still unknown: look again straight away.
        if unverified != nil { await verifyUnverified() }
    }

    func cooldown(_ type: String) -> Int { cooldowns[type] ?? 0 }

    /// The form no longer matches what the codes were issued for: drop them and let
    /// the user request fresh ones straight away (no waiting out the old cooldown).
    func invalidateCodes() {
        codeContext = nil
        cooldowns = [:]
        notice = nil
        error = Loc("地址、数量或网络改了，之前的验证码已失效，请重新获取。")
    }

    func network(forKey key: String?) -> STCurrencyNetwork? { networks.first { $0.blockchain_key == key } }

    /// The chain an address-book entry is on; an entry without one can only mean
    /// the single chain of a one-chain coin like PRL.
    func chainKey(of b: STBeneficiary) -> String? {
        b.blockchain_key ?? (networks.count == 1 ? networks[0].blockchain_key : nil)
    }

    func sendCode(type: String, address: String, amount: Decimal, context: String) async {
        guard let key = network?.blockchain_key, sendingCode == nil, cooldown(type) == 0 else { return }
        sendingCode = type; error = nil; notice = nil; ipIssue = nil
        do {
            try await client.sendWithdrawCode(type: type, address: address, amount: amount,
                                              blockchainKey: key, currency: currency)
            notice = type == "phone" ? Loc("短信验证码已发送") : Loc("验证码已发到你的 SafeTrade 注册邮箱")
            codeContext = context
            startCooldown(type)
        } catch {
            await present(error)
        }
        sendingCode = nil
    }

    /// Returns true when the exchange accepted (or may have accepted) the request,
    /// so the form can clear itself instead of inviting a second submit.
    func submit(address: String, amount: Decimal, beneficiaryID: Int?,
                emailCode: String, otpCode: String, phoneCode: String) async -> Bool {
        guard let key = network?.blockchain_key, !submitting, unverified == nil else { return false }
        let before = PendingWithdrawCheck(knownIDs: Set(history.map(\.id)), knownComplete: historyLoaded)
        submitting = true; error = nil; notice = nil; ipIssue = nil
        defer { submitting = false }
        do {
            try await client.createWithdraw(address: address, amount: amount, blockchainKey: key,
                                            beneficiaryID: beneficiaryID,
                                            emailCode: emailCode, otpCode: otpCode, phoneCode: phoneCode,
                                            currency: currency)
            codeContext = nil
            notice = Loc("提现已提交，SafeTrade 处理后会广播上链")
            await load()
            return true
        } catch SafeTradeError.withdrawUnverified {
            codeContext = nil
            trade.unverifiedWithdraws[currency] = before
            error = SafeTradeError.withdrawUnverified.errorDescription
            await verifyUnverified()
            return true
        } catch {
            await present(error)
            return false
        }
    }

    /// Settle an unverified withdrawal against the history, looking a few times (the
    /// exchange can lag a moment). A new row → it went through. Several clean looks
    /// at a history known from before the POST → it didn't, and submitting unlocks.
    /// Anything less stays locked, with 重新核对 and the website as the way out.
    func verifyUnverified() async {
        guard let check = unverified, !verifying else { return }
        verifying = true
        defer { verifying = false }
        var cleanLooks = 0
        for delay in [0, 3, 6] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let rows = try? await client.withdraws(currency: currency) else { continue }
            history = rows
            if check.knownComplete, let hit = rows.first(where: check.isNew) {
                trade.unverifiedWithdraws[currency] = nil
                error = nil
                notice = Loc("提现记录里出现了这笔提现（%@ %@），已提交成功。", hit.amountText ?? "—", currency.uppercased())
                return
            }
            cleanLooks += 1
        }
        if check.knownComplete, cleanLooks >= 2 {
            trade.unverifiedWithdraws[currency] = nil
            error = Loc("提现记录里没有新的提现，这次没有提交成功，可以重新提交。")
        } else {
            error = Loc("暂时无法确认提现结果，请到 SafeTrade 网站核对提现记录，或稍后点「重新核对」。")
        }
    }

    /// Manual override once the user has checked on the SafeTrade website.
    func dismissUnverified() {
        trade.unverifiedWithdraws[currency] = nil
        error = nil
    }

    private func present(_ error: Error) async {
        if case SafeTradeError.http(_, let body) = error,
           SafeTradeError.errorKeys(body).contains(where: { $0.hasSuffix("missing_phone_code") }) {
            needsPhoneCode = true
        }
        switch (error as? SafeTradeError)?.authProblem {
        case .untrustedIP:
            // The key's Trusted IPs list doesn't have this network's address:
            // show which address SafeTrade sees.
            self.error = nil
            ipIssue = SafeTradeIPIssue(ip: nil)
            if let ip = try? await client.publicIP() { ipIssue = SafeTradeIPIssue(ip: ip) }
            return
        case .other(let keys) where keys.contains(where: { $0.hasPrefix("authz.") }):
            // The key reads fine elsewhere (balances load), so an authz refusal here
            // means it may not withdraw: SafeTrade keys need "Enable Withdraw", which
            // in turn requires a Trusted IPs list.
            self.error = Loc("SafeTrade 拒绝了这个 API 密钥的提现请求（%@）。到 SafeTrade「API 管理」编辑这个密钥：勾选 Enable Withdraw，并把当前网络的公网 IP 加入 Trusted IPs。", keys.joined(separator: ", "))
            return
        default:
            self.error = error.localizedDescription
        }
    }

    private var cooldownRuns: [String: UUID] = [:]

    private func startCooldown(_ type: String) {
        cooldowns[type] = 60
        let run = UUID()
        cooldownRuns[type] = run   // a newer countdown for this type retires this one
        Task {
            while cooldownRuns[type] == run, cooldown(type) > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard cooldownRuns[type] == run else { return }
                cooldowns[type] = max(0, cooldown(type) - 1)
            }
        }
    }
}
