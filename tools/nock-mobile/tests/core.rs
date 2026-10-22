//! Offline checks for the NockMobile core. Run: `cargo test` (live node tests: `cargo test -- --ignored`).

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use iris_grpc_proto::pb::common::v2 as pb2;
use iris_grpc_proto::pb::public::v2 as pbw;
use iris_nockchain_types::{
    v1::{Lock, LockPrimitive, LockTim, NoteData, NoteV1, Pkh, SpendCondition},
    Name, Nicks, Note, Version,
};
use iris_ztd::{Digest, Hashable};
use nock_mobile::{account_key, call, parse_address};
use prost::Message;
use serde_json::{json, Value};

const ABANDON: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
/// `nockchain-wallet keygen` log vector (Iris iris-crypto test_keygen).
const CLI_LOG: &str = "pass destroy hub reject cricket flight camp garden scale liquid increase pool miracle fly tower file door cage vault tone night zero push crime";
/// `nockchain-wallet keygen` + `derive-child` vector (Iris slip10 test_nockchain_wallet_vector).
const CLI_CLUTCH: &str = "clutch inmate mango seek attract credit illegal popular term loyal fiber output trumpet lucky garbage merge menu certain dynamic aim trip fantasy master unveil";

fn ok(v: Value) -> Value {
    assert!(v.get("error").is_none(), "unexpected error: {v}");
    v["ok"].clone()
}

fn derive(m: &str, account: u32) -> Value {
    ok(call(&json!({ "op": "derive", "mnemonic": m, "account": account })))
}

#[test]
fn derivation_matches_official_wallet() {
    // Address + private key the official CLI logged for this seed.
    assert_eq!(derive(CLI_LOG, 0)["address"], "AyzPiJoqcqmdZdjxZ9aGLnVsbYcCphidHERKBWVXyKhNqTirshTmicG");
    let k = account_key(CLI_LOG, 0).unwrap();
    assert_eq!(
        hex(&k.private_key.unwrap().to_be_bytes()),
        "362b4073814e43f427983a83f11efcceb6741082c18f0d64b7e47340ba4485ba"
    );
    // Private key + chain code `nockchain-wallet keygen` printed for this seed.
    let k = account_key(CLI_CLUTCH, 0).unwrap();
    assert_eq!(bs58::encode(k.private_key.unwrap().to_be_bytes()).into_string(), "3MoHxVXWAr9qny12Sw8ZZtrgEBFcZegQQVkwYyePb9LZ");
    assert_eq!(bs58::encode(k.chain_code).into_string(), "3NhBRdy7vRw8vKQ5RnR3CNcD43WDn5Ky7mhhotqUcaiR");
    assert_eq!(derive(CLI_CLUTCH, 0)["address"], "3b3eG8WgWHfXTeAMJzNDWxM3b6WFadxQiiJRQrY6zPJ4J2F5QtHjZRQ");
}

#[test]
fn twelve_word_seed_derives() {
    // The 12-word BIP39 test vector — the length Pearl Hub generates.
    let a = derive(ABANDON, 0);
    assert_eq!(a["address"], "3zxKWhhd8HY9pT2ZCZNUSEz2XWwSk15P2sD3atnnnxRtHa2Ta1H4jRy");
    assert_eq!(derive(ABANDON, 1)["address"], "6RJZqW9NfrBuvakJ8fMcoH4Qb6A24Soxbp1SELkHW1PnoA6wPU5Hqvr");
    // Case and spacing don't change the key (the app trims/lowercases, users paste oddly).
    let messy = format!("  {}  ", ABANDON.to_uppercase().replace(' ', "   "));
    assert_eq!(derive(&messy, 0)["address"], a["address"]);
    assert!(a["firstNames"]["simple"].as_str().unwrap().len() > 40);
    assert_ne!(a["firstNames"]["simple"], a["firstNames"]["coinbase"]);
}

#[test]
fn watch_matches_derive() {
    let d = derive(ABANDON, 0);
    let w = ok(call(&json!({ "op": "watch", "address": d["address"] })));
    assert_eq!(w, d);
}

#[test]
fn bad_mnemonic_is_rejected() {
    let bad = ABANDON.replace("about", "abandon"); // checksum fails
    let r = call(&json!({ "op": "derive", "mnemonic": bad }));
    assert_eq!(r["code"], "invalid_mnemonic");
}

#[test]
fn first_name_matches_live_chain() {
    // Coinbase first-name of a mainnet miner, verified against rpc.nockbox.org (UTXO at 168950).
    let pkh = parse_address("Atr7NTWSqwiYFUqiwnvV7em8x3GiJKMs6VvzDxNXgDsQUYptgxfnT72").unwrap();
    let cb = SpendCondition(vec![LockPrimitive::Pkh(Pkh::single(pkh)), LockPrimitive::Tim(LockTim::coinbase())]);
    assert!(cb.first_name().to_string().starts_with("BeZ1AGS1"));
}

#[test]
fn address_validation() {
    let good = "3zxKWhhd8HY9pT2ZCZNUSEz2XWwSk15P2sD3atnnnxRtHa2Ta1H4jRy";
    assert!(parse_address(good).is_ok());
    assert!(parse_address(&format!("  {good}\n")).is_ok());
    assert!(parse_address(&good[..30]).is_err(), "truncated");
    assert!(parse_address(&format!("1{good}")).is_err(), "non-canonical leading 1");
    assert!(parse_address(&good.replace('W', "0")).is_err(), "0 is not base58");
    assert!(parse_address("prl1p2fx5wqxyz").is_err());
    // Above p^5: 55 'z's decodes to ~2^322.
    assert!(parse_address(&"z".repeat(55)).is_err());
    // A v0 address (raw 97-byte public key, ~132 chars) gets its own reason.
    let k = account_key(ABANDON, 0).unwrap();
    let v0 = bs58::encode(k.public_key.to_be_bytes()).into_string();
    assert_eq!(parse_address(&v0).unwrap_err().code, "legacy_address");
    let r = ok(call(&json!({ "op": "checkAddress", "address": good })));
    assert_eq!(r["valid"], true);
}

// MARK: - Building

/// A note locked to `cond` as the chain would name it (first = commitment to the lock).
fn note(cond: &SpendCondition, assets: u64, origin: u32, salt: u64) -> String {
    let first = cond.first_name();
    let last = (true, salt, 0u64).hash();
    let n = Note::V1(NoteV1 {
        version: Version::V1,
        origin_page: origin,
        name: Name::new(first, last),
        note_data: NoteData::empty(),
        assets: Nicks(assets),
    });
    B64.encode(pb2::Note::from(n).encode_to_vec())
}

fn own_pkh(m: &str) -> Digest {
    account_key(m, 0).unwrap().public_key.hash()
}

fn n(v: &Value) -> u64 {
    v.as_str().unwrap().parse().unwrap()
}

const NOCK: u64 = 65_536;
const RECIPIENT: &str = "3b3eG8WgWHfXTeAMJzNDWxM3b6WFadxQiiJRQrY6zPJ4J2F5QtHjZRQ";

fn wallet_notes() -> Vec<String> {
    let pkh = own_pkh(ABANDON);
    let simple = SpendCondition::new_pkh(Pkh::single(pkh));
    let coinbase = SpendCondition(vec![LockPrimitive::Pkh(Pkh::single(pkh)), LockPrimitive::Tim(LockTim::coinbase())]);
    let foreign = SpendCondition::new_pkh(Pkh::single(own_pkh(CLI_CLUTCH)));
    vec![
        note(&simple, 30 * NOCK, 168_000, 1),
        note(&simple, 5 * NOCK, 168_100, 2),
        note(&coinbase, 50 * NOCK, 168_000, 3), // mature at tip 169_000
        note(&coinbase, 70 * NOCK, 168_950, 4), // still locked at tip 169_000
        note(&foreign, 999 * NOCK, 168_000, 5), // someone else's
    ]
}

fn build(amount: u64, sweep: bool) -> Value {
    call(&json!({
        "op": "buildSend", "mnemonic": ABANDON, "notes": wallet_notes(),
        "recipient": RECIPIENT, "amount": amount.to_string(), "sweep": sweep, "height": 169_000,
    }))
}

#[test]
fn builds_and_signs_a_payment() {
    let r = ok(build(40 * NOCK, false));
    let (sent, fee, change, input) = (n(&r["amount"]), n(&r["fee"]), n(&r["change"]), n(&r["inputTotal"]));
    assert_eq!(sent, 40 * NOCK);
    assert!(fee >= n(&r["minFee"]) && fee >= 256);
    assert_eq!(input, sent + fee + change);
    // Only mature notes we own: 30 + 5 + 50 (the locked 70 and the foreign 999 are skipped).
    assert_eq!(n(&r["spendableTotal"]), 85 * NOCK);
    // Biggest-first: the mature 50 NOCK coinbase note covers 40 + fee alone.
    assert_eq!(r["inputs"].as_array().unwrap().len(), 1);
    assert_eq!(input, 50 * NOCK);
    // 60 NOCK needs the 50 and the 30.
    let r2 = ok(build(60 * NOCK, false));
    assert_eq!(r2["inputs"].as_array().unwrap().len(), 2);
    assert_eq!(n(&r2["returning"]), n(&r2["change"]));
    assert_eq!(n(&r2["inputTotal"]), 80 * NOCK);
    assert_eq!(n(&r2["inputTotal"]), n(&r2["amount"]) + n(&r2["fee"]) + n(&r2["change"]));
    eprintln!("60 NOCK from 2 inputs: fee {} nicks", n(&r2["fee"]));
    // The body is a WalletSendTransactionRequest whose tx id is the one reported.
    let body = pbw::WalletSendTransactionRequest::decode(B64.decode(r["body"].as_str().unwrap()).unwrap().as_slice()).unwrap();
    let id: Digest = body.tx_id.unwrap().try_into().unwrap();
    assert_eq!(id.to_string(), r["txId"].as_str().unwrap());
    let raw: iris_nockchain_types::RawTx = body.raw_tx.unwrap().try_into().unwrap();
    assert_eq!(raw.id().to_string(), r["txId"].as_str().unwrap());
    eprintln!("40 NOCK from {} inputs: fee {} nicks ({:.4} NOCK)", r["inputs"].as_array().unwrap().len(), fee, fee as f64 / NOCK as f64);
}

#[test]
fn send_to_self_counts_amount_not_change() {
    let me = derive(ABANDON, 0)["address"].as_str().unwrap().to_string();
    let r = ok(call(&json!({
        "op": "buildSend", "mnemonic": ABANDON, "notes": wallet_notes(),
        "recipient": me, "amount": (NOCK).to_string(), "height": 169_000,
    })));
    assert_eq!(r["toSelf"], true);
    assert_eq!(n(&r["amount"]), NOCK);
    // Everything but the fee comes back.
    assert_eq!(n(&r["returning"]), n(&r["inputTotal"]) - n(&r["fee"]));
    assert_eq!(n(&r["change"]), n(&r["returning"]) - NOCK);
    assert!(r["outputs"].as_array().unwrap().iter().all(|o| o["mine"] == true));
}

#[test]
fn an_unreadable_note_does_not_fail_the_page() {
    use iris_grpc_proto::pb::common::v1 as pb1;
    let mut entries: Vec<pb2::BalanceEntry> = wallet_notes()
        .iter()
        .map(|b| pb2::BalanceEntry { name: None, note: Some(pb2::Note::decode(B64.decode(b).unwrap().as_slice()).unwrap()) })
        .collect();
    // A v1 note with no name / data — the conversion rejects it.
    entries.push(pb2::BalanceEntry {
        name: None,
        note: Some(pb2::Note { note_version: Some(pb2::note::NoteVersion::V1(pb2::NoteV1::default())) }),
    });
    let resp = pbw::WalletGetBalanceResponse {
        result: Some(pbw::wallet_get_balance_response::Result::Balance(pb2::Balance {
            notes: entries,
            height: Some(pb1::BlockHeight { value: 169_000 }),
            block_id: None,
            page: None,
        })),
    };
    let r = ok(call(&json!({ "op": "decodeBalance", "data": B64.encode(resp.encode_to_vec()) })));
    assert_eq!(r["notes"].as_array().unwrap().len(), 5);
    assert_eq!(r["skipped"], 1);
}

#[test]
fn sweep_sends_everything_minus_fee() {
    let r = ok(build(0, true));
    let (sent, fee, change) = (n(&r["amount"]), n(&r["fee"]), n(&r["change"]));
    assert_eq!(change, 0, "sweep leaves no change");
    assert_eq!(sent + fee, 85 * NOCK);
    assert!(fee >= n(&r["minFee"]));
    eprintln!("sweep: fee {} nicks", fee);
}

#[test]
fn insufficient_and_zero_are_reported() {
    assert_eq!(build(85 * NOCK, false)["code"], "insufficient"); // no room for the fee
    assert_eq!(build(0, false)["code"], "zero_amount");
    let none = call(&json!({
        "op": "buildSend", "mnemonic": CLI_LOG, "notes": wallet_notes(),
        "recipient": RECIPIENT, "amount": "1", "height": 169_000,
    }));
    assert_eq!(none["code"], "no_funds", "another seed owns none of these notes");
}

#[test]
fn deterministic_signatures() {
    // Same inputs → same tx id (deterministic nonces), so a retried build is the same tx.
    assert_eq!(ok(build(7 * NOCK, false))["txId"], ok(build(7 * NOCK, false))["txId"]);
}

#[test]
fn balance_page_is_decoded_and_tagged() {
    use iris_grpc_proto::pb::common::v1 as pb1;
    let entries = wallet_notes()
        .iter()
        .map(|b| {
            let note = pb2::Note::decode(B64.decode(b).unwrap().as_slice()).unwrap();
            pb2::BalanceEntry { name: None, note: Some(note) }
        })
        .collect();
    let resp = pbw::WalletGetBalanceResponse {
        result: Some(pbw::wallet_get_balance_response::Result::Balance(pb2::Balance {
            notes: entries,
            height: Some(pb1::BlockHeight { value: 169_000 }),
            block_id: None,
            page: Some(pb1::PageResponse { next_page_token: "next".into() }),
        })),
    };
    let r = ok(call(&json!({
        "op": "decodeBalance", "data": B64.encode(resp.encode_to_vec()),
        "address": derive(ABANDON, 0)["address"],
    })));
    assert_eq!(r["height"], 169_000);
    assert_eq!(r["nextPageToken"], "next");
    let kinds: Vec<_> = r["notes"].as_array().unwrap().iter().map(|n| (n["kind"].as_str().unwrap().to_string(), n["spendable"].as_bool().unwrap())).collect();
    assert_eq!(kinds, vec![
        ("simple".into(), true), ("simple".into(), true),
        ("coinbase".into(), true), ("coinbase".into(), false), ("foreign".into(), false),
    ]);
    assert_eq!(r["notes"][3]["unlockHeight"], 169_050);
}

#[test]
fn requests_encode() {
    let fname = derive(ABANDON, 0)["firstNames"]["simple"].clone();
    let b = ok(call(&json!({ "op": "balanceRequest", "firstName": fname, "pageToken": "abc" })));
    let req = pbw::WalletGetBalanceRequest::decode(B64.decode(b["body"].as_str().unwrap()).unwrap().as_slice()).unwrap();
    assert_eq!(req.page.unwrap().page_token, "abc");
    let txid = "Aa7RfPQ5giF1fZYpqLZtRFg482YnKn6ffRevHXT4ko2Qs6hfqgFh3of";
    assert!(ok(call(&json!({ "op": "acceptedRequest", "txId": txid })))["body"].is_string());
    assert!(ok(call(&json!({ "op": "txDetailsRequest", "txId": txid })))["body"].is_string());
    assert!(ok(call(&json!({ "op": "blockRequest", "height": 168950 })))["body"].is_string());
    assert_eq!(call(&json!({ "op": "nope" }))["code"], "bad_request");
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// MARK: - Live (network) — `cargo test -- --ignored`

fn grpc_web(method: &str, body_b64: &str) -> Vec<u8> {
    let body = B64.decode(body_b64).unwrap();
    let mut framed = vec![0u8];
    framed.extend_from_slice(&(body.len() as u32).to_be_bytes());
    framed.extend_from_slice(&body);
    let dir = std::env::temp_dir().join(format!("nock-live-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (req, resp) = (dir.join("req.bin"), dir.join("resp.bin"));
    std::fs::write(&req, &framed).unwrap();
    let st = std::process::Command::new("curl")
        .args(["-sS", "--noproxy", "*", "-m", "30", "-X", "POST"])
        .arg(format!("https://rpc.nockbox.org/{method}"))
        .args(["-H", "content-type: application/grpc-web+proto", "--data-binary"])
        .arg(format!("@{}", req.display()))
        .arg("-o").arg(&resp)
        .status().unwrap();
    assert!(st.success());
    let d = std::fs::read(&resp).unwrap();
    // First data frame (flag 0).
    let mut i = 0;
    while i + 5 <= d.len() {
        let len = u32::from_be_bytes([d[i + 1], d[i + 2], d[i + 3], d[i + 4]]) as usize;
        if d[i] & 0x80 == 0 {
            return d[i + 5..i + 5 + len].to_vec();
        }
        i += 5 + len;
    }
    panic!("no data frame: {:?}", String::from_utf8_lossy(&d));
}

#[test]
#[ignore]
fn live_balance_tx_and_block() {
    let miner = "Atr7NTWSqwiYFUqiwnvV7em8x3GiJKMs6VvzDxNXgDsQUYptgxfnT72";
    let pkh = parse_address(miner).unwrap();
    let cb = SpendCondition(vec![LockPrimitive::Pkh(Pkh::single(pkh)), LockPrimitive::Tim(LockTim::coinbase())]);
    let req = ok(call(&json!({ "op": "balanceRequest", "firstName": cb.first_name().to_string() })));
    let page = grpc_web("nockchain.public.v2.NockchainService/WalletGetBalance", req["body"].as_str().unwrap());
    let r = ok(call(&json!({ "op": "decodeBalance", "data": B64.encode(page), "address": miner })));
    let notes = r["notes"].as_array().unwrap();
    eprintln!("tip {} — {} coinbase notes; first: {}", r["height"], notes.len(), notes.first().map(|n| n.to_string()).unwrap_or_default().chars().take(200).collect::<String>());
    assert!(!notes.is_empty());
    assert!(notes.iter().all(|n| n["kind"] == "coinbase"));

    let tx = ok(call(&json!({ "op": "txDetailsRequest", "txId": "Aa7RfPQ5giF1fZYpqLZtRFg482YnKn6ffRevHXT4ko2Qs6hfqgFh3of" })));
    let d = ok(call(&json!({ "op": "decodeTxDetails", "data": B64.encode(grpc_web("nockchain.public.v2.NockchainBlockService/GetTransactionDetails", tx["body"].as_str().unwrap())) })));
    eprintln!("tx: {d}");
    assert_eq!(d["height"], 168984);
    assert_eq!(d["fee"], "245760");

    let page = ok(call(&json!({ "op": "blocksRequest", "limit": 50 })));
    let d = ok(call(&json!({ "op": "decodeBlocks", "data": B64.encode(grpc_web("nockchain.public.v2.NockchainBlockService/GetBlocks", page["body"].as_str().unwrap())) })));
    let blocks = d["blocks"].as_array().unwrap();
    assert_eq!(blocks.len(), 50);
    assert!(blocks[0]["height"].as_u64().unwrap() > blocks[49]["height"].as_u64().unwrap());
    assert!(!d["nextPageToken"].as_str().unwrap().is_empty());

    let b = ok(call(&json!({ "op": "blockRequest", "height": 168984 })));
    let d = ok(call(&json!({ "op": "decodeBlock", "data": B64.encode(grpc_web("nockchain.public.v2.NockchainBlockService/GetBlockDetails", b["body"].as_str().unwrap())) })));
    assert_eq!(d["height"], 168984);
    assert!(d["time"].as_u64().unwrap() > 1_790_000_000);
}

#[allow(dead_code)]
fn _lock_type_check(c: SpendCondition) -> Lock {
    Lock::from(c)
}

/// Writes the Swift test fixture (Tests/Fixtures/nock_notes.json): notes of the `abandon`
/// wallet as the node would return them. `cargo test write_swift_fixture -- --ignored`.
#[test]
#[ignore]
fn write_swift_fixture() {
    let out = json!({
        "mnemonic": ABANDON,
        "address": derive(ABANDON, 0)["address"],
        "height": 169_000,
        "notes": wallet_notes(),
        "recipient": RECIPIENT,
    });
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../Tests/Fixtures/nock_notes.json");
    std::fs::write(path, serde_json::to_string_pretty(&out).unwrap()).unwrap();
}
