//! For the PRL Wallet's tests (prl-hub-wallet), which run this crate as WebAssembly:
//! - write_wasm_vectors: the native build's replies to a fixed set of requests, written to
//!   $NOCK_VECTORS_OUT (test/nock-vectors.json); the WebAssembly build must give the same bytes.
//! - write_wallet_qa_fixtures: the nodes' replies for the `abandon` wallet, written to
//!   $NOCK_FIXTURES_OUT (test/nock-fixtures.json), for the browser QA's stand-in nodes.
//! `NOCK_VECTORS_OUT=… NOCK_FIXTURES_OUT=… cargo test --test vectors -- --ignored`
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use iris_grpc_proto::pb::common::v1 as pb1;
use iris_grpc_proto::pb::common::v2 as pb2;
use iris_grpc_proto::pb::public::v2 as pbw;
use iris_nockchain_types::{v1::{LockPrimitive, LockTim, NoteData, NoteV1, Pkh, SpendCondition}, Name, Nicks, Note, Version};
use iris_ztd::{Digest, Hashable};
use nock_mobile::{account_key, call};
use prost::Message;
use serde_json::{json, Value};

const ABANDON: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const CLI_LOG: &str = "pass destroy hub reject cricket flight camp garden scale liquid increase pool miracle fly tower file door cage vault tone night zero push crime";
const CLI_CLUTCH: &str = "clutch inmate mango seek attract credit illegal popular term loyal fiber output trumpet lucky garbage merge menu certain dynamic aim trip fantasy master unveil";
const NOCK: u64 = 65_536;
const RECIPIENT: &str = "3b3eG8WgWHfXTeAMJzNDWxM3b6WFadxQiiJRQrY6zPJ4J2F5QtHjZRQ";

fn note(cond: &SpendCondition, assets: u64, origin: u32, salt: u64) -> String {
    let n = Note::V1(NoteV1 { version: Version::V1, origin_page: origin, name: Name::new(cond.first_name(), (true, salt, 0u64).hash()), note_data: NoteData::empty(), assets: Nicks(assets) });
    B64.encode(pb2::Note::from(n).encode_to_vec())
}
fn pkh(m: &str) -> Digest { account_key(m, 0).unwrap().public_key.hash() }
fn notes() -> Vec<String> {
    let p = pkh(ABANDON);
    let simple = SpendCondition::new_pkh(Pkh::single(p));
    let coinbase = SpendCondition(vec![LockPrimitive::Pkh(Pkh::single(p)), LockPrimitive::Tim(LockTim::coinbase())]);
    let foreign = SpendCondition::new_pkh(Pkh::single(pkh(CLI_CLUTCH)));
    vec![note(&simple, 30 * NOCK, 168_000, 1), note(&simple, 5 * NOCK, 168_100, 2), note(&coinbase, 50 * NOCK, 168_000, 3), note(&coinbase, 70 * NOCK, 168_950, 4), note(&foreign, 999 * NOCK, 168_000, 5)]
}
fn page(next: &str) -> String {
    let entries = notes().iter().map(|b| pb2::BalanceEntry { name: None, note: Some(pb2::Note::decode(B64.decode(b).unwrap().as_slice()).unwrap()) }).collect();
    B64.encode(pbw::WalletGetBalanceResponse { result: Some(pbw::wallet_get_balance_response::Result::Balance(pb2::Balance {
        notes: entries, height: Some(pb1::BlockHeight { value: 169_000 }), block_id: None, page: Some(pb1::PageResponse { next_page_token: next.into() }) })) }.encode_to_vec())
}

#[test]
#[ignore]
fn write_wasm_vectors() {
    let me = call(&json!({"op":"derive","mnemonic":ABANDON}))["ok"]["address"].clone();
    let fname = call(&json!({"op":"derive","mnemonic":ABANDON}))["ok"]["firstNames"]["simple"].clone();
    let txid = "Aa7RfPQ5giF1fZYpqLZtRFg482YnKn6ffRevHXT4ko2Qs6hfqgFh3of";
    let send = |extra: Value| { let mut r = json!({"op":"buildSend","mnemonic":ABANDON,"notes":notes(),"recipient":RECIPIENT,"height":169000}); for (k, v) in extra.as_object().unwrap() { r[k] = v.clone(); } r };
    let requests = vec![
        json!({"op":"version"}),
        json!({"op":"derive","mnemonic":ABANDON,"account":0}),
        json!({"op":"derive","mnemonic":ABANDON,"account":1}),
        json!({"op":"derive","mnemonic":CLI_LOG}),
        json!({"op":"derive","mnemonic":CLI_CLUTCH}),
        json!({"op":"derive","mnemonic":"abandon abandon abandon"}),
        json!({"op":"watch","address":RECIPIENT}),
        json!({"op":"checkAddress","address":RECIPIENT}),
        json!({"op":"checkAddress","address":&RECIPIENT[..30]}),
        json!({"op":"checkAddress","address":"z".repeat(132)}),
        json!({"op":"checkAddress","address":"prl1pqvwgxsx2qxlz0q9m"}),
        json!({"op":"balanceRequest","firstName":fname,"pageToken":"abc"}),
        json!({"op":"decodeBalance","data":page("next"),"address":me}),
        json!({"op":"decodeBalance","data":page("")}),
        send(json!({"amount":(40*NOCK).to_string()})),
        send(json!({"amount":(60*NOCK).to_string()})),
        send(json!({"amount":(7*NOCK).to_string()})),
        send(json!({"sweep":true})),
        send(json!({"recipient":me,"amount":NOCK.to_string()})),
        send(json!({"amount":(85*NOCK).to_string()})),
        send(json!({"amount":"0"})),
        send(json!({"mnemonic":CLI_LOG,"amount":"1"})),
        json!({"op":"acceptedRequest","txId":txid}),
        json!({"op":"txDetailsRequest","txId":txid}),
        json!({"op":"blockRequest","height":168950}),
        json!({"op":"blocksRequest","limit":500,"pageToken":""}),
        json!({"op":"nope"}),
    ];
    let pairs: Vec<Value> = requests.into_iter().map(|r| { let reply = call(&r); json!({"request": r, "reply": reply}) }).collect();
    std::fs::write(std::env::var("NOCK_VECTORS_OUT").unwrap(), serde_json::to_string(&json!({"generator":"nock-core native build (cargo test, host)","pairs":pairs})).unwrap()).unwrap();
}

/// GetBlocksResponse as the explorer API encodes it (only the fields the core reads).
#[derive(Clone, PartialEq, prost::Message)]
struct BlockEntry { #[prost(uint64, tag = "2")] height: u64, #[prost(uint64, tag = "4")] timestamp: u64 }
#[derive(Clone, PartialEq, prost::Message)]
struct BlocksData { #[prost(message, repeated, tag = "1")] blocks: Vec<BlockEntry>, #[prost(uint64, tag = "2")] current_height: u64 }
#[derive(Clone, PartialEq, prost::Message)]
struct GetBlocksResponse { #[prost(message, optional, tag = "1")] blocks: Option<BlocksData> }

#[test]
#[ignore]
fn write_wallet_qa_fixtures() {
    let p = pkh(ABANDON);
    let simple = SpendCondition::new_pkh(Pkh::single(p));
    let coinbase = SpendCondition(vec![LockPrimitive::Pkh(Pkh::single(p)), LockPrimitive::Tim(LockTim::coinbase())]);
    let balance = |notes: Vec<String>| {
        let entries = notes.iter().map(|b| pb2::BalanceEntry { name: None, note: Some(pb2::Note::decode(B64.decode(b).unwrap().as_slice()).unwrap()) }).collect();
        B64.encode(pbw::WalletGetBalanceResponse { result: Some(pbw::wallet_get_balance_response::Result::Balance(pb2::Balance {
            notes: entries, height: Some(pb1::BlockHeight { value: 169_000 }), block_id: None, page: Some(pb1::PageResponse { next_page_token: String::new() }) })) }.encode_to_vec())
    };
    // Block times: Urbit @da seconds (the core turns them into Unix time).
    let urbit_epoch = 0x8000_000c_ce9e_0d80u64;
    let blocks = GetBlocksResponse { blocks: Some(BlocksData { current_height: 169_000, blocks: [169_000u64, 168_950, 168_100, 168_000].iter()
        .map(|h| BlockEntry { height: *h, timestamp: urbit_epoch + 1_792_400_000 + (h - 168_000) * 150 }).collect() }) };
    let out = json!({
        "generator": "nock-core tests/vectors.rs write_wallet_qa_fixtures",
        "mnemonic": ABANDON,
        "address": call(&json!({"op":"derive","mnemonic":ABANDON}))["ok"]["address"],
        "firstNames": call(&json!({"op":"derive","mnemonic":ABANDON}))["ok"]["firstNames"],
        "recipient": RECIPIENT,
        // 30 + 5 NOCK payments; a mature 50 NOCK block reward and a 70 NOCK one locked until 169,050.
        "balanceSimple": balance(vec![note(&simple, 30 * NOCK, 168_000, 1), note(&simple, 5 * NOCK, 168_100, 2)]),
        "balanceCoinbase": balance(vec![note(&coinbase, 50 * NOCK, 168_000, 3), note(&coinbase, 70 * NOCK, 168_950, 4)]),
        "blocks": B64.encode(blocks.encode_to_vec()),
        "accepted": B64.encode(pbw::TransactionAcceptedResponse { result: Some(pbw::transaction_accepted_response::Result::Accepted(true)) }.encode_to_vec()),
        "notAccepted": B64.encode(pbw::TransactionAcceptedResponse { result: Some(pbw::transaction_accepted_response::Result::Accepted(false)) }.encode_to_vec()),
        "sendAck": B64.encode(pbw::WalletSendTransactionResponse { result: Some(pbw::wallet_send_transaction_response::Result::Ack(pb1::Acknowledged {})) }.encode_to_vec()),
    });
    std::fs::write(std::env::var("NOCK_FIXTURES_OUT").unwrap(), serde_json::to_string_pretty(&out).unwrap()).unwrap();
}
