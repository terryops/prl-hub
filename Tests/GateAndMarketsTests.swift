import Foundation
import CoreGraphics
import Testing
@testable import Pearl

struct GateClientTests {
    @Test func signatureMatchesReferenceHMACSHA512() {
        #expect(GateClient.sha512Hex(Data())
                == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")

        let getSig = GateClient.signature(
            method: "GET",
            path: "/api/v4/spot/orders",
            query: "currency_pair=PEARL_USDT&status=open",
            body: Data(),
            timestamp: "1790474921",
            apiSecret: "gate-secret-123"
        )
        #expect(getSig == "2f7c41873cb3f4ef2fdef00f6a598992381fabdcceac6d45f425ec97a65052e6280d816f6e5294fcabab77d775326ca8f55a442faac71b1fc727bd5027526f5f")

        let body = Data(#"{"currency_pair":"PEARL_USDT","side":"buy","type":"limit","time_in_force":"gtc","amount":"10","price":"1.52"}"#.utf8)
        let postSig = GateClient.signature(
            method: "POST",
            path: "/api/v4/spot/orders",
            query: "",
            body: body,
            timestamp: "1790474921",
            apiSecret: "gate-secret-123"
        )
        #expect(postSig == "a3bca29cff0c3de8fae9294375d1a066d67330c62dfca8672b11acaa822a5c196f67b6f969cb7c62a6209affb575370fb432ce5f9c1a3315e04b0c0ae945c698")
    }

    @Test func timestampGeneratorCompensatesClockSkew() async {
        let server = Date(timeIntervalSince1970: 1_790_474_921) // Sun, 27 Sep 2026 02:08:41 GMT
        let gen = GateTimestampGenerator(clock: { server.addingTimeInterval(120) })
        #expect(await gen.next() == "1790475041")
        await gen.observe(serverDate: "Sun, 27 Sep 2026 02:08:41 GMT")
        #expect(await gen.next() == "1790474921")
    }

    @Test func gateAuthAndOrderErrorsAreClassified() {
        #expect(GateClient.authProblem(status: 401, body: #"{"label":"INVALID_KEY","message":"Invalid key provided"}"#) == .badKey)
        #expect(GateClient.authProblem(status: 401, body: #"{"label":"INVALID_SIGNATURE","message":"Signature mismatch"}"#) == .badKey)
        #expect(GateClient.authProblem(status: 401, body: #"{"label":"REQUEST_EXPIRED","message":"Timestamp expired"}"#) == .clock)
        #expect(GateClient.isExpiredTimestamp(body: #"{"label":"REQUEST_EXPIRED"}"#))
        #expect(GateClient.authProblem(status: 403, body: #"{"label":"INVALID_IP","message":"IP not in whitelist"}"#) == .untrustedIP)
        #expect(GateClient.authProblem(status: 403, body: "<html>Forbidden</html>") == .firewall)
        #expect(GateClient.authProblem(status: 403, body: #"{"label":"FORBIDDEN","message":"No permission"}"#) == .other(["FORBIDDEN"]))

        let balMsg = GateClient.errorMessage(status: 400, body: #"{"label":"BALANCE_NOT_ENOUGH","message":"Not enough"}"#)
        #expect(balMsg == Loc("Gate 可用余额不足"))
    }

    @Test func tickerCandlesAndRulesParseGateWireShapes() throws {
        let tickerJSON = Data(#"[{"currency_pair":"PEARL_USDT","last":"1.5220","lowest_ask":"1.5230","highest_bid":"1.5210","change_percentage":"-2.15","base_volume":"84210.5","high_24h":"1.5900","low_24h":"1.4800"}]"#.utf8)
        let ticker = try GateClient.parseTicker(from: tickerJSON)
        #expect(ticker.last == "1.5220")
        #expect(ticker.buy == "1.5230")    // lowest_ask = price you buy at
        #expect(ticker.sell == "1.5210")   // highest_bid = price you sell at
        #expect(ticker.price_change_percent == "-2.15%")

        // Gate candlesticks: [ts, quote_vol, close, high, low, open, base_vol, closed]
        let candlesJSON = Data(#"[[1790474400,"15220.0","1.5400","1.5600","1.5000","1.5100","10000.5",true]]"#.utf8)
        let candles = GateClient.parseCandles(from: candlesJSON)
        #expect(candles.count == 1)
        #expect(candles[0].open == 1.51)
        #expect(candles[0].high == 1.56)
        #expect(candles[0].low == 1.50)
        #expect(candles[0].close == 1.54)
        #expect(candles[0].volume == 10000.5)

        let rulesJSON = Data(#"{"id":"PEARL_USDT","amount_precision":1,"precision":4,"min_base_amount":"0.1","min_quote_amount":"3","fee":"0.2","up_rate":"0.3","down_rate":"0.3"}"#.utf8)
        let rules = try GateClient.parseMarketRules(from: rulesJSON)
        #expect(rules == SafeTradeMarketRules.gatePearlUsdt)
        #expect(rules.problem(amountText: "1.0", priceText: "1.52") == .belowMinQuote(3))
        #expect(rules.problem(amountText: "2.0", priceText: "1.52") == nil)
        #expect(rules.problem(amountText: "1.0", priceText: nil, referencePrice: Decimal(string: "1.52")) == .belowMinQuote(3))

        // 50% custom slippage is clamped inside Gate's ±30% price protection band (29.7%)
        let cappedUp = rules.marketPriceCap(side: "buy", last: Decimal(string: "1.5000")!, slippage: Decimal(string: "0.50")!)
        #expect(cappedUp == Decimal(string: "1.9455")!)
        // MAX market buy (3.3 PEARL with 5.143881 USDT available, bestAsk 1.5168): clamps 1.7424 -> 1.5587 so amount*cap <= available
        let affordableCap = rules.gateAffordableBuyCap(
            cap: Decimal(string: "1.7424")!,
            minExecutablePrice: Decimal(string: "1.5168")!,
            amount: Decimal(string: "3.3")!,
            availableQuote: Decimal(string: "5.143881")!
        )
        #expect(affordableCap == Decimal(string: "1.5587")!)
        #expect(affordableCap * Decimal(string: "3.3")! <= Decimal(string: "5.143881")!)
    }

    @Test func ordersAndMultichainDepositsMapCleanly() throws {
        let limitBody = try GateClient.orderBody(side: "buy", amount: "10.5", price: "1.5200", maxPrice: nil, type: "limit")
        #expect(limitBody["time_in_force"] == "gtc")
        #expect(limitBody["price"] == "1.5200")

        let marketBody = try GateClient.orderBody(side: "sell", amount: "10.5", price: nil, maxPrice: "1.3100", type: "market")
        #expect(marketBody["type"] == "limit")
        #expect(marketBody["time_in_force"] == "ioc")
        #expect(marketBody["price"] == "1.3100")

        let iocFilled = Data(#"{"id":"789012345678","currency_pair":"PEARL_USDT","side":"buy","type":"limit","time_in_force":"ioc","price":"1.6000","amount":"10.0","status":"cancelled","finish_as":"ioc","filled_amount":"10.0","filled_total":"15.22","avg_deal_price":"1.5220","create_time_ms":1790474921000}"#.utf8)
        let parsed = try GateClient.parseOrder(iocFilled)
        #expect(parsed.order.cancelKey == "789012345678")
        #expect(parsed.order.type == "market")
        #expect(parsed.order.state == "done")
        #expect(parsed.order.displayPrice == "1.5220")

        // Gate status=finished omits zero-fill cancelled orders; absentMeansDone settles immediately once balances unlock
        #expect(SafeTradeStore.isSettled(nil, balancesMoved: true, absentMeansDone: true, done: { !$0.isOpen }))
        #expect(!SafeTradeStore.isSettled(nil, balancesMoved: false, absentMeansDone: true, done: { !$0.isOpen }))
        #expect(!SafeTradeStore.isSettled(nil, balancesMoved: true, absentMeansDone: false, done: { !$0.isOpen }))

        let depJSON = Data(#"{"currency":"USDT","address":"","multichain_addresses":[{"chain":"TON","address":"EQB1234567890abcdef1234567890","payment_id":"998877","obtain_failed":0}]}"#.utf8)
        let dep = try GateClient.parseDepositAddress(from: depJSON, currency: "usdt", network: "TON")
        #expect(dep.isReady)
        #expect(dep.plainAddress == "EQB1234567890abcdef1234567890")
        #expect(dep.memo == "998877")

        // First-time PEARL generation status sentence must never be treated as a blockchain address
        let generatingFallback = Data(#"{"currency":"PEARL","address":"New address is being generated for you, please wait a moment and refresh this page. ","multichain_addresses":[]}"#.utf8)
        let pendingDep = try GateClient.parseDepositAddress(from: generatingFallback, currency: "pearl", network: "PEARL")
        #expect(!pendingDep.isReady)
        #expect(pendingDep.address == nil)
    }

    @Test func gateSavedAddressesAndPerChainMinimumsMatchLivePayloads() throws {
        let savedJSON = Data(#"""
        [
          {"currency":"Universal address","chain":"ETH","address":"0x52908400098527886E0F7030069857D2E4169EE7","name":"Main ETH","tag":"","verified":"1"},
          {"currency":"Universal Address","chain":"BSC","address":"0x1111111111111111111111111111111111111111","name":"Binance","tag":"","verified":"1"},
          {"currency":"USDT","chain":"BSC","address":"0x2222222222222222222222222222222222222222","name":"Unverified","tag":"","verified":"0"}
        ]
        """#.utf8)
        let saved = try GateClient.parseSavedAddresses(from: savedJSON)
        #expect(saved.count == 3)
        // Universal addresses map currencyID to nil so WithdrawStore keeps them for any coin supporting that chain
        #expect(saved[0].currencyID == nil)
        #expect(saved[0].isActive)
        #expect(saved[0].blockchain_key == "ETH")
        #expect(saved[1].currencyID == nil)
        #expect(saved[2].currencyID == "usdt")
        #expect(!saved[2].isActive)

        let chainsJSON = Data(#"""
        [
          {"chain":"PEARL","name_cn":"PEARL","name_en":"PEARL","is_disabled":0,"is_deposit_disabled":0,"is_withdraw_disabled":0,"decimal":"8","is_tag":0,"withdraw_amount_min":"0.01"},
          {"chain":"ETH","name_cn":"Ethereum（ERC20）","name_en":"Ethereum(ERC20)","is_disabled":0,"is_deposit_disabled":0,"is_withdraw_disabled":0,"decimal":"6","is_tag":0,"withdraw_amount_min":"1"},
          {"chain":"BSC","name_cn":"BSC","name_en":"BSC","is_disabled":0,"is_deposit_disabled":0,"is_withdraw_disabled":0,"decimal":"8","is_tag":0,"withdraw_amount_min":"1"},
          {"chain":"TRX","name_cn":"Tron","name_en":"Tron(TRC20)","is_disabled":0,"is_deposit_disabled":0,"is_withdraw_disabled":0,"decimal":"6","is_tag":0,"withdraw_amount_min":"10"},
          {"chain":"GRAM","name_cn":"TON","name_en":"The Open Network (TON)","is_disabled":0,"is_deposit_disabled":0,"is_withdraw_disabled":0,"decimal":"6","is_tag":1,"withdraw_amount_min":"1"}
        ]
        """#.utf8)
        let statusJSON = Data(#"[{"currency":"USDT","withdraw_amount_mini":"1","withdraw_fix_on_chains":{"ETH":"1","BSC":"0.500","TRX":"1.50","GRAM":"0.30"}}]"#.utf8)
        let parsed = try GateClient.parseCurrency(chainsData: chainsJSON, statusData: statusJSON, useChinese: false, currency: "USDT")
        #expect(parsed.precision == 8)
        let pearlNet = parsed.networks.first { $0.blockchain_key == "PEARL" }
        let eth = parsed.networks.first { $0.blockchain_key == "ETH" }
        let bsc = parsed.networks.first { $0.blockchain_key == "BSC" }
        let trx = parsed.networks.first { $0.blockchain_key == "TRX" }
        let gram = parsed.networks.first { $0.blockchain_key == "GRAM" }
        #expect(eth?.minAmount == 1)
        #expect(eth?.withdrawPrecision == 6)
        #expect(bsc?.withdrawPrecision == 8)
        #expect(trx?.minAmount == 10)
        #expect(gram?.requiresMemo == true)
        #expect(pearlNet?.explorerURL(txid: "abc")?.absoluteString == "https://blockbook.pearlresearch.ai/tx/abc")
        #expect(gram?.explorerURL(txid: "def")?.absoluteString == "https://tonviewer.com/transaction/def")

        let whitelistBody = #"{"label":"WITHDRAW_ADDRESS_NOT_WHITELISTED","message":"Withdrawal address is not in whitelist"}"#
        #expect(GateClient.isAddressNotWhitelisted(body: whitelistBody))
        #expect(GateClient.authProblem(status: 403, body: whitelistBody) == nil)
    }

    @Test func gateChainAddressValidation() throws {
        func net(_ key: String) throws -> STCurrencyNetwork {
            let data = Data(#"{"blockchain_key":"\#(key)","withdraw_enabled":true,"deposit_enabled":true,"status":"active"}"#.utf8)
            return try JSONDecoder().decode(STCurrencyNetwork.self, from: data)
        }
        #expect(try net("TRX").isValidAddress("TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL"))
        #expect(try !net("TRX").isValidAddress("0x0000000000000000000000000000000000000000"))
        #expect(try net("ARBEVM").isValidAddress("0x52908400098527886E0F7030069857D2E4169EE7"))
        #expect(try net("KAIA").isValidAddress("0x52908400098527886E0F7030069857D2E4169EE7"))
        #expect(try !net("KAIA").isValidAddress("0x52908400098527886E0F7030069857D2E4169ee7")) // invalid EIP-55
        #expect(try net("NEAR").isValidAddress("alice.near"))
        #expect(try net("NEAR").isValidAddress(String(repeating: "a", count: 64)))
        #expect(try !net("NEAR").isValidAddress("not valid address"))
        #expect(try net("TON").isValidAddress("EQDtFpEwcFAEcRe5mLVh2N6C0x-_hJEM7W61_JLnSF74p4q2"))
    }
}

struct TradeMarketsAggregationTests {
    @Test func fallbackSnapshotAggregatesCEXAndPoolsAndShares() throws {
        let cg = Data(#"""
        {"tickers":[
          {"base":"PEARL","target":"USDT","market":{"name":"BigONE","identifier":"bigone"},"converted_last":{"usd":1.52},"converted_volume":{"usd":5000000},"trade_url":"https://big.one/en/trade/PEARL-USDT"},
          {"base":"PRL","target":"USDT","market":{"name":"Ourbit","identifier":"ourbit"},"converted_last":{"usd":1.52},"converted_volume":{"usd":2000000},"trade_url":"https://www.ourbit.com/exchange/PRL_USDT"},
          {"base":"PEARL","target":"USDT","market":{"name":"LBank","identifier":"lbank"},"converted_last":{"usd":1.52},"converted_volume":{"usd":1500000},"trade_url":"https://www.lbank.com/trade/pearl_usdt"},
          {"base":"PEARL","target":"USD","market":{"name":"Coinbase Exchange","identifier":"gdax"},"converted_last":{"usd":1.52},"converted_volume":{"usd":1500000},"trade_url":"https://www.coinbase.com/advanced-trade/spot/PEARL-USD"},
          {"base":"PEARL","target":"USDT","market":{"name":"SafeTrade","identifier":"safe_trade"},"converted_last":{"usd":1.51},"converted_volume":{"usd":1000000},"trade_url":"https://safetrade.com/exchange/PEARL-USDT"},
          {"base":"PRL.OMFT.NEAR","target":"17208628F84F5D6AD33F0DA3BBBEB27FFCB398EAC501A31BD6AD2011E36133A1","market":{"name":"Rhea Finance","identifier":"ref_finance"},"converted_last":{"usd":1.52},"converted_volume":{"usd":1200000},"trade_url":"https://app.rhea.finance/"},
          {"base":"PRL.OMFT.NEAR","target":"17208628F84F5D6AD33F0DA3BBBEB27FFCB398EAC501A31BD6AD2011E36133A1","market":{"name":"Near Intents","identifier":"near-intents"},"converted_last":{"usd":1.52},"converted_volume":{"usd":1500000},"trade_url":null},
          {"base":"PRL.OMFT.NEAR","target":"ETH-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48.OMFT.NEAR","market":{"name":"Near Intents","identifier":"near-intents"},"converted_last":{"usd":1.52},"converted_volume":{"usd":500000},"trade_url":null}
        ]}
        """#.utf8)
        let gate = Data(#"[{"currency_pair":"PEARL_USDT","last":"1.525","quote_volume":"2000000"}]"#.utf8)
        let dex = Data(#"""
        {"pairs":[
          {"chainId":"near","dexId":"rhea-finance","url":"https://dexscreener.com/near/rhea0","baseToken":{"address":"prl.omft.near","symbol":"PEARL"},"quoteToken":{"address":"17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1","symbol":"USDC"},"priceUsd":"1.525","volume":{"h24":1250000},"liquidity":{"usd":840000}},
          {"chainId":"near","dexId":"rhea-finance","url":"https://dexscreener.com/near/rhea1","baseToken":{"address":"prl.omft.near","symbol":"PEARL"},"quoteToken":{"address":"wrap.near","symbol":"wNEAR"},"priceUsd":"1.53","volume":{"h24":500000},"liquidity":{"usd":320000}}
        ]}
        """#.utf8)

        let snap = TradeMarketsClient.buildFallbackSnapshot(coingeckoData: cg, gateData: gate, dexScreenerData: dex)
        #expect(snap.items.count == 6)
        #expect(!snap.items.contains { $0.venue == "BigONE" || $0.venue == "Ourbit" || $0.venue == "LBank" })
        // 1.5M Coinbase + 1M SafeTrade + 2M Gate + 2M Intents (1.5M+0.5M) + 1.25M Rhea USDC (no double count!) + 0.5M Rhea wNEAR = 8.25M
        #expect(snap.totalVolumeUsd24h == 8_250_000)
        #expect(snap.cexVolumeUsd24h == 4_500_000)
        #expect(snap.poolVolumeUsd24h == 3_750_000)

        let stItem = snap.items.first { $0.id == "safetrade:pearl/usdt" }
        #expect(stItem?.inAppExchange == "safetrade")

        let gateItem = snap.items.first { $0.id == "gate:pearl/usdt" }
        #expect(gateItem?.inAppExchange == "gate")
        #expect(gateItem?.priceUsd == 1.525)

        let intentsItem = snap.items.first { $0.venue == "Near Intents" }
        #expect(intentsItem?.pair == "PEARL/USDC")
        #expect(intentsItem?.volumeUsd24h == 2_000_000)
        #expect(intentsItem?.isPool == true)
        #expect(intentsItem?.tradeUrl == "https://app.near-intents.org/")

        let rheaUsdc = snap.items.first { $0.id == "rhea-finance:pearl/usdc" }
        #expect(rheaUsdc?.isPool == true)
        #expect(rheaUsdc?.volumeUsd24h == 1_250_000)
        #expect(rheaUsdc?.liquidityUsd == 840_000)

        let rheaWnear = snap.items.first { $0.id == "rhea-finance:pearl/wnear" }
        #expect(rheaWnear?.liquidityUsd == 320_000)

        let slices = MarketVolumeSlice.build(from: snap.items, total: snap.totalVolumeUsd24h)
        #expect(abs(slices.reduce(0) { $0 + $1.share } - 1.0) < 1e-9)

        let workerJSON = Data(#"""
        {"ok":true,"schemaVersion":1,"ts":1794747000,"stale":false,"totalVolumeUsd24h":3000000,"cexVolumeUsd24h":3000000,"poolVolumeUsd24h":0,"rows":[{"id":"gate:PEARL/USDT","venue":"Gate","pair":"PEARL/USDT","kind":"cex","chain":null,"priceUsd":1.52,"volumeUsd24h":3000000,"liquidityUsd":null,"share":1.0,"tradeUrl":"https://www.gate.com/trade/PEARL_USDT","inAppExchange":"gate"}]}
        """#.utf8)
        let decodedWorker = try JSONDecoder().decode(MarketsSnapshot.self, from: workerJSON)
        #expect(decodedWorker.items.count == 1)
        #expect(decodedWorker.updatedAt != nil)
    }

    @Test func keyGuideEndpointsAndEnglishTranslationsExist() {
        #expect(TradeExchange.gate.apiManagementURL.absoluteString == "https://www.gate.com/myaccount/apikeys")
        #expect(TradeExchange.safetrade.apiManagementURL.absoluteString == "https://safetrade.com/my/api")

        let enPath = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        let requiredKeys = [
            "创建 API v4 密钥",
            "网页端右上角头像进入「API 管理」（手机 App 在左上角头像 →「安全中心 / 更多 → API 管理」），点「创建 API Key」，在「账户类型」弹窗里选「交易账户」，备注随便填（如 Pearl Hub），API Key 类型选「API v4 Key」。",
            "「账户类型」弹窗有三种：选「交易账户」。不要选「模拟交易」（虚拟盘，无法读写实盘资产），也不要选「第三方应用」（仅限 Gate 预设的合作托管平台固定服务器 IP，Pearl Hub 由你的设备本机直连 Gate）。",
            "登录 gate.com 或 Gate App，确保账户已开启谷歌验证（2FA）和资金密码。",
            "开启「现货 → 读写」（仅查余额可选「只读」）和「钱包 → 只读」（查充值地址、提币手续费与地址簿必需）；「提现 → 读写」按需开启，其余合约、杠杆等全部保持关闭。",
            "选「绑定 IP」并填入当前网络的公网 IP（多个 IP 用英文逗号隔开，最多 20 个）：",
            "填写 API 密钥",
            "SafeTrade 与 Gate API 密钥",
            "收款地址不在 Gate 提币白名单中。请先到 Gate 网站将该地址加入白名单并完成验证。",
        ]
        if let bundle = enPath {
            for k in requiredKeys {
                let localized = bundle.localizedString(forKey: k, value: "__MISSING__", table: nil)
                #expect(localized != "__MISSING__" && localized != k)
            }
        }
    }

    @Test @MainActor func savedExchangePersistsAcrossStoreInitAndSwitches() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: TradeExchange.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: TradeExchange.storageKey)
            } else {
                defaults.removeObject(forKey: TradeExchange.storageKey)
            }
        }

        TradeExchange.save(.gate)
        #expect(TradeExchange.saved == .gate)
        let restoredGate = SafeTradeStore()
        #expect(restoredGate.exchange == .gate)

        TradeExchange.save(.safetrade)
        #expect(TradeExchange.saved == .safetrade)
        restoredGate.adoptSavedExchange()
        #expect(restoredGate.exchange == .safetrade)

        let freshStore = SafeTradeStore()
        #expect(freshStore.exchange == .safetrade)
    }

    @Test func donutHitTestMapsClockwiseRingAndExcludesHoleAndMargins() {
        let slices = [
            MarketVolumeSlice(id: "gate", name: "Gate", volumeUsd: 250, share: 0.25, isPool: false),
            MarketVolumeSlice(id: "intents", name: "Near Intents", volumeUsd: 500, share: 0.50, isPool: true),
            MarketVolumeSlice(id: "safetrade", name: "SafeTrade", volumeUsd: 250, share: 0.25, isPool: false),
        ]
        // Wide card frame: 360x196 -> center (180, 98), outer radius 98, inner radius 58.
        let frame = CGRect(x: 0, y: 0, width: 360, height: 196)
        let inner: CGFloat = 58
        func at(deg: Double, r: CGFloat = 76) -> CGPoint {
            let rad = deg * .pi / 180
            return CGPoint(x: frame.midX + CGFloat(sin(rad)) * r,
                           y: frame.midY - CGFloat(cos(rad)) * r)
        }

        // Clockwise sectors: [0°, 90°] = gate, (90°, 270°] = intents, (270°, 360°) = safetrade.
        #expect(MarketVolumeSlice.hitTest(at: at(deg: 0), in: frame, innerRadius: inner, slices: slices)?.id == "gate")
        #expect(MarketVolumeSlice.hitTest(at: at(deg: 45), in: frame, innerRadius: inner, slices: slices)?.id == "gate")
        #expect(MarketVolumeSlice.hitTest(at: at(deg: 135), in: frame, innerRadius: inner, slices: slices)?.id == "intents")
        #expect(MarketVolumeSlice.hitTest(at: at(deg: 220), in: frame, innerRadius: inner, slices: slices)?.id == "intents")
        #expect(MarketVolumeSlice.hitTest(at: at(deg: 315), in: frame, innerRadius: inner, slices: slices)?.id == "safetrade")
        #expect(MarketVolumeSlice.hitTest(at: at(deg: 359.5), in: frame, innerRadius: inner, slices: slices)?.id == "safetrade")

        // Center hole and wide-card side margins do not hit any sector.
        #expect(MarketVolumeSlice.hitTest(at: CGPoint(x: 180, y: 98), in: frame, innerRadius: inner, slices: slices) == nil)
        #expect(MarketVolumeSlice.hitTest(at: at(deg: 45, r: 40), in: frame, innerRadius: inner, slices: slices) == nil)
        #expect(MarketVolumeSlice.hitTest(at: CGPoint(x: 320, y: 98), in: frame, innerRadius: inner, slices: slices) == nil)
    }
}
