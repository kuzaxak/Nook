#!/bin/sh
# Builds libnook_adblock.a (release, stripped) for macOS (arm64 + x86_64 universal), iOS arm64 and the iOS
# simulator and wraps them in NookAdblock.xcframework so machines without a Rust
# toolchain can still build Nook.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"
# Keep cargo output out of Nook/ (a filesystem-synchronized Xcode group would
# otherwise copy every target/ file into the app bundle). build/ is gitignored.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/../../../build/AdblockRustFFI-target}"

cargo test --release --locked
cargo build --release --locked --target aarch64-apple-darwin
cargo build --release --locked --target x86_64-apple-darwin
cargo build --release --locked --target aarch64-apple-ios
cargo build --release --locked --target aarch64-apple-ios-sim
mkdir -p "$CARGO_TARGET_DIR/universal-macos/release"
lipo -create \
  "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libnook_adblock.a" \
  "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/libnook_adblock.a" \
  -output "$CARGO_TARGET_DIR/universal-macos/release/libnook_adblock.a"
rm -rf NookAdblock.xcframework
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/universal-macos/release/libnook_adblock.a" -headers include \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libnook_adblock.a" -headers include \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libnook_adblock.a" -headers include \
  -output NookAdblock.xcframework
ls NookAdblock.xcframework
