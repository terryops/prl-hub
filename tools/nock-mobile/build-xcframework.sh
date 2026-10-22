#!/bin/bash
# Builds vendor/NockMobile.xcframework (iOS device, iOS simulator, macOS) from this crate.
# Needs rustup's toolchain with the Apple targets (brew install rustup; see README.md) and
# protoc (brew install protobuf). Run from anywhere.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/vendor/NockMobile.xcframework"
RUSTUP_BIN="${RUSTUP_BIN:-/opt/homebrew/opt/rustup/bin}"
export PATH="$RUSTUP_BIN:$PATH"
export PROTOC="${PROTOC:-$(command -v protoc)}"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0
# Reproducible-ish: no absolute paths of this machine in panic messages.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~"

cd "$HERE"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin)
rustup target add "${TARGETS[@]}" >/dev/null
for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release --target $t"
  cargo build --locked --release --lib --target "$t"
done
cargo test --locked --release

LIB=libnock_mobile.a
STAGE="$HERE/target/xcframework"
rm -rf "$STAGE" && mkdir -p "$STAGE/ios" "$STAGE/sim" "$STAGE/mac"
cp "target/aarch64-apple-ios/release/$LIB" "$STAGE/ios/$LIB"
lipo -create "target/aarch64-apple-ios-sim/release/$LIB" "target/x86_64-apple-ios/release/$LIB" -output "$STAGE/sim/$LIB"
lipo -create "target/aarch64-apple-darwin/release/$LIB" "target/x86_64-apple-darwin/release/$LIB" -output "$STAGE/mac/$LIB"

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$STAGE/ios/$LIB" -headers "$HERE/include" \
  -library "$STAGE/sim/$LIB" -headers "$HERE/include" \
  -library "$STAGE/mac/$LIB" -headers "$HERE/include" \
  -output "$OUT"
echo "built $OUT"
du -sh "$OUT"
