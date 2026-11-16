//! NockMobile — the Nockchain (NOCK) half of Pearl Hub's wallet.
//!
//! The app's 12-word BIP39 seed also opens a NOCK account, derived exactly like the official
//! `nockchain-wallet` and Iris do (BIP39 seed → HMAC-SHA512 key "Nockchain seed" → master key;
//! the default account IS the master key). Everything chain-specific lives here — key
//! derivation, protobuf encode/decode for the public gRPC API, spend-condition matching, and
//! building + signing v1 (Bythos) transactions — so Swift only moves bytes over URLSession.
//!
//! One C entry point: `nock_call(json)` → JSON `{"ok": …}` or `{"error": …, "code": …}`.
//! The returned string is owned by Rust and must be released with `nock_free`.
//! Nothing here touches the network or the disk.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ibig::UBig;
use prost::Message;
use serde_json::{json, Value};

use iris_crypto::{derive_master_key, ExtendedKey};
use iris_grpc_proto::pb::common::v1 as pb1;
use iris_grpc_proto::pb::common::v2 as pb2;
use iris_grpc_proto::pb::public::v2 as pbw;
use iris_nockchain_types::{
    builder::TxBuilder,
    v1::{Lock, LockPrimitive, LockTim, NoteV1, Pkh, SpendCondition},
    BlockHeight, Nicks, Note, TimelockRange, TxEngineSettings,
};
use iris_ztd::{Digest, Hashable};

/// Explorer messages (tx / block details) generated from the official protos in proto/.
#[allow(clippy::all, dead_code)]
mod upstream {
    pub mod nockchain {
        pub mod common {
            pub mod v1 {
                include!(concat!(env!("OUT_DIR"), "/nockchain.common.v1.rs"));
            }
            pub mod v2 {
                include!(concat!(env!("OUT_DIR"), "/nockchain.common.v2.rs"));
            }
        }
        pub mod public {
            pub mod v2 {
                include!(concat!(env!("OUT_DIR"), "/nockchain.public.v2.rs"));
            }
        }
    }
}
use upstream::nockchain::common::v1 as up1;
use upstream::nockchain::public::v2 as upx;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// 1 NOCK = 2^16 nicks.
pub const NICKS_PER_NOCK: u64 = 65_536;
/// Coinbase outputs unlock this many blocks after the block that mined them.
pub const COINBASE_TIMELOCK: u64 = 100;
/// Goldilocks prime; a digest is 5 base-p limbs, so a valid address is < p^5.
const PRIME: u64 = 0xffff_ffff_0000_0001;
/// Urbit `@da` seconds of 1970-01-01 — page timestamps are Urbit time.
const URBIT_UNIX_EPOCH: u64 = 0x8000_000c_ce9e_0d80;

// MARK: - Errors

#[derive(Debug)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
}

impl Failure {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
}

type Res<T> = Result<T, Failure>;

fn bad(message: impl Into<String>) -> Failure {
    Failure::new("bad_request", message)
}

// MARK: - FFI

/// Runs one operation. `request` is UTF-8 JSON `{"op": "...", ...params}`.
///
/// # Safety
/// `request` must be null or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn nock_call(request: *const c_char) -> *mut c_char {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Res<Value> {
        if request.is_null() {
            return Err(bad("null request"));
        }
        let text = CStr::from_ptr(request).to_str().map_err(|_| bad("request is not UTF-8"))?;
        let req: Value = serde_json::from_str(text).map_err(|e| bad(format!("request is not JSON: {e}")))?;
        dispatch(&req)
    }));
    let reply = match outcome {
        Ok(Ok(v)) => json!({ "ok": v }),
        Ok(Err(f)) => json!({ "error": f.message, "code": f.code }),
        Err(_) => json!({ "error": "internal error", "code": "panic" }),
    };
    CString::new(reply.to_string()).unwrap_or_default().into_raw()
}

/// Frees a string returned by `nock_call`.
///
/// # Safety
/// `s` must be null or a pointer returned by `nock_call`, freed at most once.
#[no_mangle]
pub unsafe extern "C" fn nock_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// WebAssembly hosts (the PRL Wallet extension, and the wallet inside the Android app) write the
/// request into the module's memory: `nock_alloc(len)` returns a buffer for it and
/// `nock_dealloc(ptr, len)` gives it back once `nock_call` has returned. Not built for the Apple
/// targets. On wasm32 a panic aborts (traps) instead of unwinding, so the host must drop the
/// instance after a trap rather than keep using it.
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn nock_alloc(len: usize) -> *mut u8 {
    match std::alloc::Layout::array::<u8>(len.max(1)) {
        Ok(layout) => unsafe { std::alloc::alloc(layout) },
        Err(_) => std::ptr::null_mut(),
    }
}

/// # Safety
/// `ptr` must be null or come from `nock_alloc(len)` with the same `len`, freed at most once.
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub unsafe extern "C" fn nock_dealloc(ptr: *mut u8, len: usize) {
    if let (false, Ok(layout)) = (ptr.is_null(), std::alloc::Layout::array::<u8>(len.max(1))) {
        std::alloc::dealloc(ptr, layout);
    }
}

/// Same contract as `nock_call`, for Rust callers and tests.
pub fn call(req: &Value) -> Value {
    match catch_unwind(AssertUnwindSafe(|| dispatch(req))) {
        Ok(Ok(v)) => json!({ "ok": v }),
        Ok(Err(f)) => json!({ "error": f.message, "code": f.code }),
        Err(_) => json!({ "error": "internal error", "code": "panic" }),
    }
}

fn dispatch(req: &Value) -> Res<Value> {
    let op = str_param(req, "op")?;
    match op {
        "version" => Ok(json!({ "version": VERSION, "nicksPerNock": NICKS_PER_NOCK })),
        "derive" => derive(req),
        "watch" => watch(req),
        "validateAddress" => Ok(json!({ "valid": parse_address(str_param(req, "address")?).is_ok() })),
        "checkAddress" => check_address(req),
        "balanceRequest" => balance_request(req),
        "decodeBalance" => decode_balance(req),
        "buildSend" => build_send(req),
        "decodeSend" => decode_send(req),
        "acceptedRequest" => accepted_request(req),
        "decodeAccepted" => decode_accepted(req),
        "txDetailsRequest" => tx_details_request(req),
        "decodeTxDetails" => decode_tx_details(req),
        "blockRequest" => block_request(req),
        "blocksRequest" => blocks_request(req),
        "decodeBlocks" => decode_blocks(req),
        "decodeBlock" => decode_block(req),
        other => Err(bad(format!("unknown op {other}"))),
    }
}

// MARK: - Params

fn str_param<'a>(req: &'a Value, key: &str) -> Res<&'a str> {
    req.get(key).and_then(Value::as_str).ok_or_else(|| bad(format!("missing {key}")))
}

/// u64 given as a JSON number or a decimal string (Swift sends nicks as strings).
fn u64_param(req: &Value, key: &str) -> Res<u64> {
    match req.get(key) {
        Some(Value::Number(n)) => n.as_u64().ok_or_else(|| bad(format!("{key} is not a u64"))),
        Some(Value::String(s)) => s.trim().parse().map_err(|_| bad(format!("{key} is not a u64"))),
        _ => Err(bad(format!("missing {key}"))),
    }
}

fn b64_param(req: &Value, key: &str) -> Res<Vec<u8>> {
    B64.decode(str_param(req, key)?).map_err(|_| bad(format!("{key} is not base64")))
}

fn account_param(req: &Value) -> Res<u32> {
    match req.get("account") {
        None | Some(Value::Null) => Ok(0),
        Some(_) => {
            let a = u64_param(req, "account")?;
            // Non-hardened children only (Iris accounts); 2^31+ would be hardened.
            if a >= (1 << 31) {
                return Err(bad("account out of range"));
            }
            Ok(a as u32)
        }
    }
}

// MARK: - Keys & addresses

/// BIP39 (English, empty passphrase) → Nockchain SLIP-10 master key; account i ≥ 1 is the
/// master's non-hardened child i (Iris), account 0 the master itself (CLI + Iris default).
pub fn account_key(mnemonic: &str, account: u32) -> Res<ExtendedKey> {
    let words = mnemonic
        .split_whitespace()
        .map(|w| w.to_lowercase())
        .collect::<Vec<_>>()
        .join(" ");
    let m = bip39::Mnemonic::parse_in_normalized(bip39::Language::English, &words)
        .map_err(|_| Failure::new("invalid_mnemonic", "invalid mnemonic"))?;
    let master = derive_master_key(&m.to_seed_normalized(""));
    Ok(if account == 0 { master } else { master.derive_child(account) })
}

/// A v1 address is the base58 of the pubkey hash's integer value. There is no checksum, so
/// this is strict about everything it CAN check: the alphabet, the range (< p^5), canonical
/// form (re-encodes to the same text) and a realistic length — a hash below 58^40 has odds of
/// about 2^-86, so anything shorter is a truncated paste, not an address.
pub fn parse_address(raw: &str) -> Res<Digest> {
    let s = raw.trim();
    let invalid = || Failure::new("invalid_address", "invalid NOCK address");
    if s.len() > 100 {
        // ~132 chars: a v0 address (a raw public key) — retired at block 39000.
        return Err(Failure::new("legacy_address", "legacy v0 address"));
    }
    if s.len() < 40 {
        return Err(invalid());
    }
    let bytes = bs58::decode(s).into_vec().map_err(|_| invalid())?;
    if bytes.len() > 40 {
        return Err(invalid());
    }
    let p = UBig::from(PRIME);
    let limit = &p * &p * &p * &p * &p;
    if UBig::from_be_bytes(&bytes) >= limit {
        return Err(invalid());
    }
    let d = Digest::try_from(s).map_err(|_| invalid())?;
    if d.to_string() != s {
        return Err(invalid());
    }
    Ok(d)
}

fn simple_condition(pkh: Digest) -> SpendCondition {
    SpendCondition::new_pkh(Pkh::single(pkh))
}

fn timelocked_condition(pkh: Digest, tim: LockTim) -> SpendCondition {
    SpendCondition(vec![LockPrimitive::Pkh(Pkh::single(pkh)), LockPrimitive::Tim(tim)].into())
}

/// Where an owned note's spend condition came from, and from which height it can be spent.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum NoteKind {
    /// Plain payment to the address.
    Simple,
    /// Mining reward: locked for `COINBASE_TIMELOCK` blocks after its block.
    Coinbase,
    /// Absolute-height timelock (origin + 100) some wallets use for coinbase-like outputs.
    Absolute,
}

impl NoteKind {
    fn label(self) -> &'static str {
        match self {
            NoteKind::Simple => "simple",
            NoteKind::Coinbase => "coinbase",
            NoteKind::Absolute => "timelock",
        }
    }
}

/// The spend conditions this wallet can satisfy for a note born at `origin`, in the order
/// Iris tries them. A note's `name.first` commits to its lock, so a match proves both that
/// the note is ours and which condition unlocks it.
fn candidates(pkh: Digest, origin: u64) -> Vec<(NoteKind, SpendCondition, u64)> {
    let abs_min = origin.saturating_add(COINBASE_TIMELOCK);
    let mut out = vec![
        (NoteKind::Simple, simple_condition(pkh), 0),
        (NoteKind::Coinbase, timelocked_condition(pkh, LockTim::coinbase()), abs_min),
    ];
    if let Ok(min) = BlockHeight::try_from(abs_min) {
        let abs = LockTim {
            rel: TimelockRange::none(),
            abs: TimelockRange { min: Some(min), max: None },
        };
        out.push((NoteKind::Absolute, timelocked_condition(pkh, abs), abs_min));
    }
    out
}

/// (kind, condition, first spendable height) for a note we own, or None if it isn't ours /
/// uses a lock this wallet doesn't build.
fn match_note(pkh: Digest, note: &NoteV1) -> Option<(NoteKind, SpendCondition, u64)> {
    candidates(pkh, note.origin_page as u64)
        .into_iter()
        .find(|(_, cond, _)| cond.first_name() == note.name.first)
}

/// Spendable in a block built on top of `tip`. One block of margin on timelocks: the node
/// may check against its tip rather than the next block.
fn is_mature(unlock_height: u64, tip: u64) -> bool {
    tip >= unlock_height
}

fn derive(req: &Value) -> Res<Value> {
    let key = account_key(str_param(req, "mnemonic")?, account_param(req)?)?;
    let pkh = key.public_key.hash();
    Ok(json!({
        "address": pkh.to_string(),
        "firstNames": {
            "simple": simple_condition(pkh).first_name().to_string(),
            "coinbase": timelocked_condition(pkh, LockTim::coinbase()).first_name().to_string(),
        },
    }))
}

/// First-names for any address (read-only: balance and history, no key).
fn watch(req: &Value) -> Res<Value> {
    let pkh = parse_address(str_param(req, "address")?)?;
    Ok(json!({
        "address": pkh.to_string(),
        "firstNames": {
            "simple": simple_condition(pkh).first_name().to_string(),
            "coinbase": timelocked_condition(pkh, LockTim::coinbase()).first_name().to_string(),
        },
    }))
}

/// Validates a pasted address, and says whether it is this wallet's own.
fn check_address(req: &Value) -> Res<Value> {
    match parse_address(str_param(req, "address")?) {
        Ok(d) => Ok(json!({ "valid": true, "address": d.to_string() })),
        Err(f) => Ok(json!({ "valid": false, "reason": f.code })),
    }
}

// MARK: - Balance (WalletGetBalance by first-name)

fn balance_request(req: &Value) -> Res<Value> {
    let first_name = str_param(req, "firstName")?;
    Digest::try_from(first_name).map_err(|_| bad("firstName is not a digest"))?;
    let page_token = req.get("pageToken").and_then(Value::as_str).unwrap_or("").to_string();
    let msg = pbw::WalletGetBalanceRequest {
        selector: Some(pbw::wallet_get_balance_request::Selector::FirstName(pb1::Base58Hash {
            hash: first_name.to_string(),
        })),
        page: Some(pb1::PageRequest { client_page_items_limit: 0, page_token, max_bytes: 0 }),
    };
    Ok(json!({ "body": B64.encode(msg.encode_to_vec()) }))
}

fn server_error(e: &pb1::ErrorStatus) -> Failure {
    Failure::new("server", format!("{} (code {})", e.message, e.code))
}

fn up_server_error(e: &up1::ErrorStatus) -> Failure {
    Failure::new("server", format!("{} (code {})", e.message, e.code))
}

fn pb_hash_text(h: Option<pb1::Hash>) -> Option<String> {
    h.and_then(|h| Digest::try_from(h).ok()).map(|d| d.to_string())
}

/// One page of a WalletGetBalance response → its notes, tagged for the wallet `address`
/// (optional): which lock each one uses and from which height it can be spent.
fn decode_balance(req: &Value) -> Res<Value> {
    let bytes = b64_param(req, "data")?;
    let owner = match req.get("address").and_then(Value::as_str) {
        Some(a) => Some(parse_address(a)?),
        None => None,
    };
    let resp = pbw::WalletGetBalanceResponse::decode(bytes.as_slice())
        .map_err(|e| Failure::new("decode", format!("balance: {e}")))?;
    let balance = match resp.result {
        Some(pbw::wallet_get_balance_response::Result::Balance(b)) => b,
        Some(pbw::wallet_get_balance_response::Result::Error(e)) => return Err(server_error(&e)),
        None => return Err(Failure::new("decode", "empty balance response")),
    };
    let tip = balance.height.as_ref().map(|h| h.value);
    let mut notes = Vec::new();
    let mut skipped = 0u32;
    for entry in balance.notes {
        let Some(pb_note) = entry.note else { continue };
        let raw = B64.encode(pb_note.encode_to_vec());
        // One note this core can't read (odd note data, a future version) is left out rather
        // than failing the whole page — a dust payment must not lock the wallet up.
        let Ok(note) = Note::try_from(pb_note) else {
            skipped += 1;
            continue;
        };
        match note {
            Note::V1(n) => {
                let matched = owner.and_then(|pkh| match_note(pkh, &n));
                let (kind, unlock) = match &matched {
                    Some((k, _, h)) => (k.label(), *h),
                    None => ("foreign", 0),
                };
                let spendable = matched.is_some() && tip.map(|t| is_mature(unlock, t)).unwrap_or(false);
                notes.push(json!({
                    "nameFirst": n.name.first.to_string(),
                    "nameLast": n.name.last.to_string(),
                    "originPage": n.origin_page,
                    "assets": n.assets.0.to_string(),
                    "kind": kind,
                    "unlockHeight": unlock,
                    "spendable": spendable,
                    "raw": raw,
                }));
            }
            legacy @ Note::V0(_) => notes.push(json!({
                "nameFirst": legacy.name().first.to_string(),
                "nameLast": legacy.name().last.to_string(),
                "originPage": legacy.origin_page(),
                "assets": legacy.assets().0.to_string(),
                "kind": "legacy",
                "unlockHeight": 0,
                "spendable": false,
                "raw": raw,
            })),
        }
    }
    Ok(json!({
        "height": tip,
        "blockId": pb_hash_text(balance.block_id),
        "nextPageToken": balance.page.map(|p| p.next_page_token).unwrap_or_default(),
        "notes": notes,
        "skipped": skipped,
    }))
}

// MARK: - Send (build + sign)

/// Builds and signs a payment from this wallet's notes. Params:
/// `mnemonic`, `account`?, `notes` (base64 `common.v2.Note` from decodeBalance), `recipient`,
/// `amount` (nicks; ignored when `sweep`), `sweep` (send everything spendable, fee taken from
/// it), `height` (chain tip, for timelocks and output naming).
/// Returns the WalletSendTransaction request body plus what the confirmation sheet shows.
fn build_send(req: &Value) -> Res<Value> {
    let key = account_key(str_param(req, "mnemonic")?, account_param(req)?)?;
    let signing_key = key.private_key.clone().ok_or_else(|| bad("no private key"))?;
    let pkh = key.public_key.hash();
    let recipient = parse_address(str_param(req, "recipient")?)?;
    let tip = u64_param(req, "height")?;
    let sweep = req.get("sweep").and_then(Value::as_bool).unwrap_or(false);
    let amount = if sweep { 0 } else { u64_param(req, "amount")? };
    if !sweep && amount == 0 {
        return Err(Failure::new("zero_amount", "amount must be positive"));
    }

    let raws = req.get("notes").and_then(Value::as_array).ok_or_else(|| bad("missing notes"))?;
    let mut inputs: Vec<(Note, Option<(Lock, usize)>)> = Vec::new();
    for r in raws {
        let bytes = B64.decode(r.as_str().unwrap_or("")).map_err(|_| bad("note is not base64"))?;
        let pb_note = pb2::Note::decode(bytes.as_slice()).map_err(|e| Failure::new("decode", format!("note: {e}")))?;
        let Ok(Note::V1(n)) = Note::try_from(pb_note) else { continue };
        let Some((_, cond, unlock)) = match_note(pkh, &n) else { continue };
        if !is_mature(unlock, tip) {
            continue;
        }
        inputs.push((Note::V1(n), Some((Lock::from(cond), 0))));
    }
    // Biggest first: the gift is covered by as few notes as possible (fewer inputs, lower fee);
    // the builder keeps the rest in its fee pool and only spends one if the fee needs it.
    inputs.sort_by(|a, b| b.0.assets().cmp(&a.0.assets()));
    let total: u64 = inputs.iter().map(|(n, _)| n.assets().0).sum();
    if inputs.is_empty() {
        return Err(Failure::new("no_funds", "no spendable notes"));
    }

    let settings = TxEngineSettings::v1_bythos_default();
    let builder = if sweep {
        sweep_builder(&inputs, recipient, pkh, total, &signing_key, settings.clone())?
    } else {
        let mut b = TxBuilder::new(settings.clone());
        b.simple_spend_base(inputs.clone(), recipient, Nicks(amount), pkh, false)
            .map_err(build_failure)?;
        b.recalc_and_set_fee(false).map_err(build_failure)?;
        b.sign(&signing_key);
        b.validate().map_err(build_failure)?;
        b
    };

    let fee = builder.cur_fee().0;
    let min_fee = builder.calc_fee().0;
    let tx = builder.build();
    let raw = tx.to_raw_tx();
    let tx_id = raw.id;

    let mine_first = simple_condition(pkh).first_name();
    let theirs_first = simple_condition(recipient).first_name();
    let to_self = recipient == pkh;
    let origin = BlockHeight::try_from(tip.saturating_add(1)).unwrap_or(BlockHeight::MAX);
    let mut outputs = Vec::new();
    // `returning`: everything that comes back to this wallet (change, or all of a send to self).
    let (mut sent, mut returning) = (0u64, 0u64);
    for out in raw.outputs(origin, settings.clone()) {
        let mine = out.name.first == mine_first;
        if mine {
            returning += out.assets.0;
        } else if out.name.first == theirs_first {
            sent += out.assets.0;
        }
        outputs.push(json!({
            "nameFirst": out.name.first.to_string(),
            "nameLast": out.name.last.to_string(),
            "assets": out.assets.0.to_string(),
            "mine": mine,
        }));
    }
    // A send to self: the outputs to our lock merge (gift + change), so the sent part is what
    // was asked for (or, for a sweep, everything less the fee).
    if to_self {
        sent = if sweep { total.saturating_sub(fee) } else { amount };
    }
    let change = returning.saturating_sub(if to_self { sent } else { 0 });
    let mut input_names = Vec::new();
    let mut input_total = 0u64;
    for (name, _) in raw.spends.0.iter() {
        input_names.push(json!({ "nameFirst": name.first.to_string(), "nameLast": name.last.to_string() }));
        if let Some((n, _)) = inputs.iter().find(|(n, _)| n.name() == *name) {
            input_total += n.assets().0;
        }
    }
    if input_total != sent + change + fee {
        return Err(Failure::new("internal", "unbalanced transaction"));
    }
    if to_self && returning != sent + change {
        return Err(Failure::new("internal", "unbalanced transaction"));
    }

    let body = pbw::WalletSendTransactionRequest {
        tx_id: Some(pb1::Hash::from(tx_id)),
        raw_tx: Some(pb2::RawTransaction::from(raw)),
    };
    Ok(json!({
        "txId": tx_id.to_string(),
        "fee": fee.to_string(),
        "minFee": min_fee.to_string(),
        "amount": sent.to_string(),
        "change": change.to_string(),
        "returning": returning.to_string(),
        "toSelf": to_self,
        "inputTotal": input_total.to_string(),
        "spendableTotal": total.to_string(),
        "inputs": input_names,
        "outputs": outputs,
        "body": B64.encode(body.encode_to_vec()),
    }))
}

/// Send-everything: the gift is `total − fee`, with the fee found by iterating (it depends on
/// how many notes are spent, which is all of them). The fee is pinned exactly, so no change
/// output is created.
fn sweep_builder(
    inputs: &[(Note, Option<(Lock, usize)>)],
    recipient: Digest,
    refund: Digest,
    total: u64,
    key: &iris_crypto::PrivateKey,
    settings: TxEngineSettings,
) -> Res<TxBuilder> {
    let mut fee = settings.min_fee.0;
    for _ in 0..8 {
        if fee >= total {
            return Err(Failure::new("insufficient", "balance does not cover the fee"));
        }
        let mut b = TxBuilder::new(settings.clone());
        b.simple_spend_base(inputs.to_vec(), recipient, Nicks(total - fee), refund, false)
            .map_err(build_failure)?;
        let need = b.calc_fee().0;
        if need > fee {
            fee = need;
            continue;
        }
        b.set_fee_and_balance_refund(Nicks(fee), false, false).map_err(build_failure)?;
        b.sign(key);
        match b.validate() {
            Ok(_) => return Ok(b),
            Err(iris_nockchain_types::builder::BuildError::InvalidFee(needed, _)) if needed.0 > fee => {
                fee = needed.0;
            }
            Err(e) => return Err(build_failure(e)),
        }
    }
    Err(Failure::new("internal", "fee did not converge"))
}

fn build_failure(e: iris_nockchain_types::builder::BuildError) -> Failure {
    use iris_nockchain_types::builder::BuildError as E;
    match e {
        E::InsufficientFunds => Failure::new("insufficient", "insufficient funds (amount + fee)"),
        E::ZeroGift => Failure::new("zero_amount", "amount must be positive"),
        other => Failure::new("build", format!("{other}")),
    }
}

fn decode_send(req: &Value) -> Res<Value> {
    let bytes = b64_param(req, "data")?;
    let resp = pbw::WalletSendTransactionResponse::decode(bytes.as_slice())
        .map_err(|e| Failure::new("decode", format!("send: {e}")))?;
    match resp.result {
        Some(pbw::wallet_send_transaction_response::Result::Ack(_)) => Ok(json!({ "acknowledged": true })),
        Some(pbw::wallet_send_transaction_response::Result::Error(e)) => Err(server_error(&e)),
        None => Err(Failure::new("decode", "empty send response")),
    }
}

// MARK: - Mempool acceptance

fn tx_id_param(req: &Value) -> Res<String> {
    let id = str_param(req, "txId")?.trim();
    Digest::try_from(id).map_err(|_| bad("txId is not a digest"))?;
    Ok(id.to_string())
}

fn accepted_request(req: &Value) -> Res<Value> {
    let msg = pbw::TransactionAcceptedRequest { tx_id: Some(pb1::Base58Hash { hash: tx_id_param(req)? }) };
    Ok(json!({ "body": B64.encode(msg.encode_to_vec()) }))
}

fn decode_accepted(req: &Value) -> Res<Value> {
    let bytes = b64_param(req, "data")?;
    let resp = pbw::TransactionAcceptedResponse::decode(bytes.as_slice())
        .map_err(|e| Failure::new("decode", format!("accepted: {e}")))?;
    match resp.result {
        Some(pbw::transaction_accepted_response::Result::Accepted(a)) => Ok(json!({ "accepted": a })),
        Some(pbw::transaction_accepted_response::Result::Error(e)) => Err(server_error(&e)),
        None => Err(Failure::new("decode", "empty accepted response")),
    }
}

// MARK: - Explorer (tx + block details)

fn up_hash_text(h: &Option<up1::Hash>) -> Option<String> {
    let h = h.as_ref()?;
    let belts = [&h.belt_1, &h.belt_2, &h.belt_3, &h.belt_4, &h.belt_5];
    let mut limbs = [iris_ztd::Belt(0); 5];
    for (i, b) in belts.iter().enumerate() {
        limbs[i] = iris_ztd::Belt(b.as_ref()?.value);
    }
    Some(Digest(limbs).to_string())
}

fn unix_time(urbit_seconds: u64) -> u64 {
    urbit_seconds.checked_sub(URBIT_UNIX_EPOCH).unwrap_or(urbit_seconds)
}

fn tx_details_request(req: &Value) -> Res<Value> {
    let msg = upx::GetTransactionDetailsRequest { tx_id: Some(up1::Base58Hash { hash: tx_id_param(req)? }) };
    Ok(json!({ "body": B64.encode(msg.encode_to_vec()) }))
}

fn decode_tx_details(req: &Value) -> Res<Value> {
    use upx::get_transaction_details_response::Result as R;
    use upx::transaction_details::{FeeRequired, TotalOutputRequired};
    use upx::transaction_output::AmountRequired;
    let bytes = b64_param(req, "data")?;
    let resp = upx::GetTransactionDetailsResponse::decode(bytes.as_slice())
        .map_err(|e| Failure::new("decode", format!("tx details: {e}")))?;
    match resp.result {
        Some(R::Pending(_)) => Ok(json!({ "pending": true })),
        Some(R::Error(e)) => Err(up_server_error(&e)),
        None => Err(Failure::new("decode", "empty tx details response")),
        Some(R::Details(d)) => {
            let nicks = |n: &Option<up1::Nicks>| n.as_ref().map(|v| v.value.to_string());
            Ok(json!({
                "pending": false,
                "txId": d.tx_id,
                "blockId": up_hash_text(&d.block_id),
                "height": d.height,
                "time": unix_time(d.timestamp),
                "sizeBytes": d.size_bytes,
                "totalInput": nicks(&d.total_input),
                "totalOutput": d.total_output_required.map(|TotalOutputRequired::TotalOutput(n)| n.value.to_string()),
                "fee": d.fee_required.map(|FeeRequired::Fee(n)| n.value.to_string()),
                "inputs": d.inputs.iter().map(|i| json!({
                    "name": i.note_name_b58,
                    "amount": nicks(&i.amount),
                    "sourceTxId": i.source_tx_id,
                    "coinbase": i.coinbase,
                })).collect::<Vec<_>>(),
                "outputs": d.outputs.iter().map(|o| json!({
                    "name": o.note_name_b58,
                    "amount": o.amount_required.as_ref().map(|AmountRequired::Amount(n)| n.value.to_string()),
                    "lock": o.lock_summary,
                })).collect::<Vec<_>>(),
            }))
        }
    }
}

fn block_request(req: &Value) -> Res<Value> {
    let msg = upx::GetBlockDetailsRequest {
        selector: Some(upx::get_block_details_request::Selector::Height(u64_param(req, "height")?)),
    };
    Ok(json!({ "body": B64.encode(msg.encode_to_vec()) }))
}

fn decode_block(req: &Value) -> Res<Value> {
    use upx::get_block_details_response::Result as R;
    let bytes = b64_param(req, "data")?;
    let resp = upx::GetBlockDetailsResponse::decode(bytes.as_slice())
        .map_err(|e| Failure::new("decode", format!("block: {e}")))?;
    match resp.result {
        Some(R::Details(d)) => Ok(json!({
            "height": d.height,
            "time": unix_time(d.timestamp),
            "blockId": up_hash_text(&d.block_id),
            "txIds": d.tx_ids.iter().map(|t| t.hash.clone()).collect::<Vec<_>>(),
        })),
        Some(R::Error(e)) => Err(up_server_error(&e)),
        None => Err(Failure::new("decode", "empty block response")),
    }
}

/// A page of recent blocks, newest first — timestamps for many heights in one round trip.
fn blocks_request(req: &Value) -> Res<Value> {
    let limit = req.get("limit").and_then(Value::as_u64).unwrap_or(500).min(1000) as u32;
    let page_token = req.get("pageToken").and_then(Value::as_str).unwrap_or("").to_string();
    let msg = upx::GetBlocksRequest {
        page: Some(up1::PageRequest { client_page_items_limit: limit, page_token, max_bytes: 0 }),
    };
    Ok(json!({ "body": B64.encode(msg.encode_to_vec()) }))
}

fn decode_blocks(req: &Value) -> Res<Value> {
    use upx::get_blocks_response::Result as R;
    let bytes = b64_param(req, "data")?;
    let resp = upx::GetBlocksResponse::decode(bytes.as_slice())
        .map_err(|e| Failure::new("decode", format!("blocks: {e}")))?;
    match resp.result {
        Some(R::Blocks(b)) => Ok(json!({
            "currentHeight": b.current_height,
            "nextPageToken": b.page.map(|p| p.next_page_token).unwrap_or_default(),
            "blocks": b.blocks.iter().map(|e| json!({ "height": e.height, "time": unix_time(e.timestamp) })).collect::<Vec<_>>(),
        })),
        Some(R::Error(e)) => Err(up_server_error(&e)),
        None => Err(Failure::new("decode", "empty blocks response")),
    }
}
