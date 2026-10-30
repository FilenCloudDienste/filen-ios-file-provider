#!/usr/bin/env bash

# adapted from https://github.com/ianthetechie/uniffi-starter/blob/main/rust/build-ios.sh

set -e
set -u

macos=false

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
		--macos)
			macos=true
			shift
			;;
		--help)
			echo "Usage: $0 --rust-dir RUST_DIR --rust-crate-name RUST_CRATE_NAME [--macos]"
			echo "  --macos  build the universal macOS library instead of the iOS ones"
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

copy_bindings() {
	cp target/uniffi-xcframework-staging/${libname}.swift "$xcode_dir/FilenFileProviderExtension/filen_mobile_native_cache.swift"
	# The test bundle is its own module and links the same xcframework, so it needs its own copy of the
	# bindings. Both are generated, gitignored, and regenerated together to stay in sync.
	cp target/uniffi-xcframework-staging/${libname}.swift "$xcode_dir/FilenFileProviderTests/filen_mobile_native_cache.swift"
}

# A separate xcframework, so the iOS one and this path never touch each other. The Swift bindings are
# shared by both, so build both from the same filen-rs revision.
if [ "$macos" = true ]; then
	# The File Provider floor on macOS is 14. Scoped to the build so host tools keep their fingerprint.
	MACOSX_DEPLOYMENT_TARGET=14.0 cargo build -p $rust_crate_name --lib --release --target aarch64-apple-darwin --target x86_64-apple-darwin

	rm -rf target/macos
	mkdir -p target/macos/universal
	lipo -create \
		target/aarch64-apple-darwin/release/lib${libname}.a \
		target/x86_64-apple-darwin/release/lib${libname}.a \
		-output target/macos/universal/lib${libname}.a

	cargo run -p uniffi-bindgen-swift -- target/aarch64-apple-darwin/release/lib${libname}.a target/uniffi-xcframework-staging --swift-sources --headers --modulemap --module-name ${libname}FFI --modulemap-filename module.modulemap

	xcodebuild -create-xcframework \
		-library target/macos/universal/lib${libname}.a -headers target/uniffi-xcframework-staging \
		-output target/macos/lib${libname}-macos.xcframework

	mkdir -p "$xcode_dir/Frameworks"
	rm -rf "$xcode_dir/Frameworks/lib${libname}-macos.xcframework"
	cp -R target/macos/lib${libname}-macos.xcframework "$xcode_dir/Frameworks/"
	copy_bindings
	exit 0
fi

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
copy_bindings
