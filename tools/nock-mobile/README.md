# NockMobile — the NOCK (Nockchain) wallet core

Rust → `vendor/NockMobile.xcframework` (static library + `module.modulemap`), linked into the
iOS and macOS apps. Swift side: `Sources/WalletKit/NockCore.swift` (FFI), `NockClient.swift`
(gRPC-web over URLSession), `NockWalletStore.swift`, UI in `Sources/Wallet/NockWallet.swift`.

## What it does

- **Same seed as PRL.** The wallet's 12-word BIP39 phrase also opens a NOCK account, derived like
  the official `nockchain-wallet` and Iris: BIP39 seed (empty passphrase) → HMAC-SHA512 with key
  `"Nockchain seed"` → SLIP-10 master key on the Cheetah curve. The default address is the
  **master key itself** (account 0); account *i* ≥ 1 is its non-hardened child *i* (Iris).
- **Address** = base58 of the Tip5 hash of the public key (v1 "pkh" address, ~55 chars). No
  checksum — `parse_address` checks alphabet, range (< p⁵), canonical form and length.
- **Balance**: the public node indexes notes by *first-name* (a commitment to the lock), so the
  wallet asks for two: plain payments `[pkh]` and block rewards `[pkh, tim rel ≥ 100]`.
- **Send**: notes are matched to the spend condition that unlocks them, then Iris's
  `TxBuilder::simple_spend_base` + `recalc_and_set_fee` (Bythos fee rules) + sign; MAX pins the
  fee so no change is created. Output: a `WalletSendTransactionRequest` body for the node.

Everything goes through one C function, `nock_call(json) -> json` (+ `nock_free`). It never
touches the network or the disk.

## Dependencies (pinned)

- [nockbox/iris-rs](https://github.com/nockbox/iris-rs) (MIT) at `a0a2137` — `iris-crypto`,
  `iris-ztd`, `iris-nockchain-types`, `iris-grpc-proto`. Bump the rev deliberately and rerun the
  tests (the official-wallet vectors and the live round trip) before shipping.
- `proto/` — the public API protos copied from
  [zorp-corp/nockchain](https://github.com/zorp-corp/nockchain) `9bcc26c` (MIT, see
  `proto/LICENSE-MIT`); only the explorer messages (tx / block details, block list) are
  generated from them.

## Build

```sh
brew install rustup protobuf              # rustup is keg-only: /opt/homebrew/opt/rustup/bin
tools/nock-mobile/build-xcframework.sh    # adds the Apple targets, tests, builds, packages
```

The script builds `aarch64-apple-ios`, `aarch64-apple-ios-sim` + `x86_64-apple-ios` and
`aarch64-apple-darwin` + `x86_64-apple-darwin` (iOS 17 / macOS 14), runs the tests and writes
`vendor/NockMobile.xcframework` (git-ignored, like OysterMobile). The linked app grows ~1.5 MB.

## Tests

```sh
cd tools/nock-mobile
cargo test                                  # offline: vectors, addresses, build + sign, sweep
cargo test -- --ignored live_               # live: decodes real notes / tx / blocks from rpc.nockbox.org
cargo test write_swift_fixture -- --ignored # regenerates Tests/Fixtures/nock_notes.json
```

Vectors: `pass destroy hub … push crime` → `AyzPiJoq…TmicG` (logged by `nockchain-wallet
keygen`), `clutch inmate … master unveil` private key / chain code (`nockchain-wallet keygen`),
and the 12-word `abandon … about` → `3zxKWhhd…a1H4jRy`.

## Network

Public node `https://rpc.nockbox.org` (Iris Wallet's), gRPC-web (`application/grpc-web+proto`),
so plain URLSession POSTs work. Prices: CoinGecko `nockchain`. Explorer links: nockscan.net.
