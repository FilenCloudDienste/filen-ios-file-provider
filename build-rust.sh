#!/usr/bin/env bash

# adapted from https://github.com/ianthetechie/uniffi-starter/blob/main/rust/build-ios.sh

set -e
set -u

while [[ $# -gt 0 ]]; do
	case $1 in
		--rust-dir)
			rust_dir="$2"
			shift 2
			;;
		--rust-crate-name)
			rust_crate_name="$2"
			shift 2
			;;
		--help)
			echo "Usage: $0 --rust-dir RUST_DIR --rust-crate-name RUST_CRATE_NAME"
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			exit 1
			;;
	esac
done

xcode_dir=$(pwd)

cd "$rust_dir" || { echo "Could not change directory to $rust_dir"; exit 1; }

libname=$(echo "$rust_crate_name" | tr '-' '_')

# Potential optimizations for the future:
# * Option to do debug builds instead for local development

# Build targets
cargo build -p $rust_crate_name --lib --release --target aarch64-apple-ios-sim --target aarch64-apple-ios

# Make uniffi bindings
cargo run -p uniffi-bindgen-swift -- target/aarch64-apple-ios/release/lib${libname}.a target/uniffi-xcframework-staging --swift-sources --headers --modulemap --module-name ${libname}FFI --modulemap-filename module.modulemap

# Make XCFramework
rm -rf target/ios
xcodebuild -create-xcframework \
	-library target/aarch64-apple-ios/release/lib${libname}.a -headers target/uniffi-xcframework-staging \
	-library target/aarch64-apple-ios-sim/release/lib${libname}.a -headers target/uniffi-xcframework-staging \
	-output target/ios/lib${libname}.xcframework

cp -r target/ios/lib${libname}.xcframework "$xcode_dir/Frameworks"
cp target/uniffi-xcframework-staging/${libname}.swift "$xcode_dir/FilenFileProviderExtension/filen_mobile_native_cache.swift"
