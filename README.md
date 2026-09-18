# Pearl Hub

A self-custody **Pearl ($PRL)** wallet and mining monitor for iPhone, iPad and Mac, written in native SwiftUI.

[App Store](https://apps.apple.com/app/id6777132941) · [Telegram channel @prl_hub](https://t.me/prl_hub)

## Features

- **Self-custody wallet**: create or restore wallets (12 or 24 words), keep several on one device and switch between them, receive, and send. The recovery phrase is encrypted in the Keychain, and viewing it or confirming a transfer requires Face ID / Touch ID. Transactions are signed on the device.
- **Mining monitor**: network hashrate and difficulty, a pools overview, and per-address monitors for AlphaPool, F2Pool, HeroMiners, Kryptex, Lucky Pool, Pearl Fortune and PearlHash.
- **Widgets**: an iOS home-screen widget and a macOS desktop widget.
- **Price alerts (Pearl Hub Pro)**: push notifications when PRL reaches a target price or moves sharply within 5 minutes, 1 hour or 24 hours, even while the app is closed. Unlocked by a one-time in-app purchase.
- **Trading (optional)**: a SafeTrade PRL/USDT trading tab that uses your own API keys (stored in the Keychain). It is compiled in only when the `TRADE_ENABLED` condition is set.
- **6 languages**: English, 简体中文, 繁體中文, Русский, Tiếng Việt, Bahasa Indonesia.

## How it works

- **Keys stay on the device.** `OysterMobile.xcframework` is a [gomobile](https://pkg.go.dev/golang.org/x/mobile) binding of the Pearl wallet code from [pearl-research-labs/pearl](https://github.com/pearl-research-labs/pearl). It generates the mnemonic, derives addresses, and signs transactions offline.
- **Chain data** comes from Pearl's public Blockbook indexer (`blockbook.pearlresearch.ai`), which also broadcasts signed transactions. The wallet has no backend of its own.
- **Price alerts** are the one feature with a server: a small alert service (`prl.tools.video`, not part of this repository) checks the PRL price every minute and sends notifications through Apple Push Notification service. The app sends it only the device's push token, the alert conditions and the app language (`Sources/App/PriceAlerts.swift`); no wallet data leaves the device.
- **Pool, price and exchange-rate data** come from the public APIs of each service.

## Building

Requirements: Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. Download `OysterMobile.xcframework.zip` from [Releases](../../releases) and unzip it into `vendor/`, so that `vendor/OysterMobile.xcframework` exists.
2. In `project.yml`, set `DEVELOPMENT_TEAM` to your own Apple team. Replace the bundle id `com.prl.wizard` and the App Group `group.com.prl.wizard` (in `project.yml` and the `*.entitlements` files) with identifiers you own.
3. Run `xcodegen generate`, open `PRLHub.xcodeproj`, and run the `PRLHub_iOS` or `PRLHub_macOS` scheme.

To include the trading tab, add `TRADE_ENABLED` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.

Price alerts need the Push Notifications capability on your App ID (the entitlements declare `aps-environment`), and they only work against the official alert service with the official bundle id. The Run schemes use `StoreKit/Pearl.storekit`, so the Pro purchase can be tested locally without App Store Connect.

## License

Copyright (C) 2026 Cyber Corner

Pearl Hub is free software, released under the [GNU General Public License v3.0](LICENSE).

`OysterMobile.xcframework` is distributed as a prebuilt binary. It is built from Pearl's wallet code, which is ISC-licensed. For third-party notices, see **Settings → Open Source Licenses** in the app (`Sources/Settings/LicensesView.swift`).
