import Foundation
import Testing
@testable import Pearl

/// SafeTrade top-up (充值): the shapes SafeTrade's web client reads, decoded offline.
struct DepositTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func networkDepositFieldsAndFilter() throws {
        // Trimmed from the live /trade/public/currencies/usdt reply (2026-09-27):
        // options mixes strings and numbers; Pulsechain has deposits off.
        let json = """
        {"precision":6,"networks":[
          {"blockchain_key":"bsc-tokens","protocol":"BSC","protocol_name":"Binance Smart Chain","status":"active",
           "deposit_enabled":true,"min_deposit_amount":"3","min_confirmations":3,"deposit_fee":"0",
           "explorer_transaction":"https://bscscan.com/tx/#{txid}",
           "options":{"erc20_contract_address":"0x55d3","gas_limit":207128,"gas_rate":"standard",
                      "maintenance_message":"BSC upgrade","nested":{"x":1}}},
          {"blockchain_key":"pls-key","protocol":"PLS","status":"active","deposit_enabled":false,
           "min_deposit_amount":"10","min_confirmations":10},
          {"blockchain_key":"tron-tokens","protocol":"TRON","status":"disabled","deposit_enabled":true}
        ]}
        """
        let c = try JSONDecoder().decode(STCurrency.self, from: data(json))
        #expect(c.networks.count == 3)
        #expect(c.networks.filter(\.canDeposit).map(\.blockchain_key) == ["bsc-tokens"])
        let bsc = c.networks[0]
        #expect(bsc.minDeposit == 3)
        #expect(bsc.min_confirmations == 3)
        #expect(bsc.depositFee == 0)
        #expect(bsc.maintenanceMessage == "BSC upgrade")
        #expect(bsc.options?["gas_limit"]?.text == "207128")
        #expect(bsc.options?["nested"]?.text == "")      // a non-scalar doesn't fail the network
        #expect(bsc.explorerURL(txid: "ab")?.absoluteString == "https://bscscan.com/tx/ab")
    }

    @Test func depositAddressMemoAndReadiness() throws {
        let plain = try JSONDecoder().decode(STDepositAddress.self, from: data(
            #"{"address":"0xabc","network":"bsc-tokens","currencies":["usdt","bnb"]}"#))
        #expect(plain.isReady)
        #expect(plain.plainAddress == "0xabc")
        #expect(plain.memo == nil)

        let memo = try JSONDecoder().decode(STDepositAddress.self, from: data(
            #"{"address":"rDeposit?memo=12345","network":"xrp","currencies":["xrp"]}"#))
        #expect(memo.plainAddress == "rDeposit")
        #expect(memo.memo == "12345")

        // Still being generated: an empty address.
        let pending = try JSONDecoder().decode(STDepositAddress.self, from: data(
            #"{"address":"","network":"pearl-tokens","currencies":["prl"]}"#))
        #expect(!pending.isReady)
    }

    @Test func pickAddressFromBalance() throws {
        let balance = try JSONDecoder().decode(STBalance.self, from: data("""
        {"currency":"usdt","balance":"1","locked":"0","deposit_addresses":[
          {"address":"TTron","network":"tron-tokens","currencies":["usdt","trx"]},
          {"address":"0xBsc","network":"bsc-tokens","currencies":["usdt","bnb"]},
          {"address":"","network":"arbitrum-tokens","currencies":["usdt"]}]}
        """))
        let list = try #require(balance.deposit_addresses)
        #expect(STDepositAddress.pick(list, currency: "usdt", network: "bsc-tokens")?.plainAddress == "0xBsc")
        #expect(STDepositAddress.pick(list, currency: "usdt", network: "arbitrum-tokens") == nil)  // not generated
        #expect(STDepositAddress.pick(list, currency: "usdt", network: "spl-key") == nil)
        // A balance without the field still decodes.
        let bare = try JSONDecoder().decode(STBalance.self, from: data(#"{"currency":"prl","balance":"2","locked":"0"}"#))
        #expect(bare.deposit_addresses == nil)
    }

    @Test func depositRowsDecodeLenientlyWithStatus() throws {
        let json = """
        [{"id":3,"currency":"usdt","blockchain_key":"bsc-tokens","amount":"25.5","fee":"0","credited":true,
          "txid":"0xaa","created_at":"2026-09-27T10:00:00Z"},
         {"id":2,"currency":"usdt","amount":10,"credited":false,"fee_paid":false,"fee_currency":"bnb",
          "created_at":1790000000},
         {"id":1,"currency":"usdt","amount":"5","credited":"0","state":"rejected"},
         {"id":"not-a-number"},
         {"id":4,"currency":"prl","amount":"1","credited":"0","state":"submitted"},
         {"id":5,"currency":"prl","amount":"1","state":"collected"}]
        """
        let rows = try #require(decodeRows(STDeposit.self, from: data(json)))
        #expect(rows.map(\.id) == [3, 2, 1, 4, 5])                   // the odd row is skipped
        #expect(rows[0].status == .credited)
        #expect(rows[0].amountText == "25.5")
        #expect(rows[1].status == .feeRequired)
        #expect(rows[1].amountText == "10")
        #expect(rows[2].status == .failed)
        #expect(rows[3].status == .processing)
        #expect(rows[4].status == .credited)
        #expect(rows[0].created_at?.date != nil && rows[1].created_at?.date != nil)
    }

    @Test func depositErrorKeysRead() {
        #expect(SafeTradeError.message(forKey: "account.deposit_address.network_doesnt_exist") == Loc("SafeTrade 不支持用这条链充值"))
        #expect(SafeTradeError.message(forKey: "account.currency.deposit_disabled") == Loc("SafeTrade 暂停了这个币种的充值"))
        #expect(SafeTradeError.message(forKey: "account.deposit_address.disabled_2fa")
                == Loc("SafeTrade 要求先开启谷歌验证（2FA）才能生成充值地址"))
        // Withdraw keys keep their own wording.
        #expect(SafeTradeError.message(forKey: "account.withdraw.missing_otp_code") == Loc("请填写谷歌验证码（2FA）"))
        let e = SafeTradeError.http(422, #"{"errors":["account.currency.deposit_disabled"]}"#)
        #expect(e.errorDescription == Loc("SafeTrade 暂停了这个币种的充值"))
    }
}
