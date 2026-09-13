#!/usr/bin/env bash
help='
Usage: bash build.sh COMMAND
Build, test, document, package, or clean VModalSDK.
Examples:
  bash build.sh build
  bash build.sh analyze
'
set -euo pipefail
sdk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$sdk_dir"
sdk_resolve() { local help='
    ## Usage:
      bash build.sh resolve
  '; bash install.sh check; swift package resolve; }
sdk_format() { local help='
    ## Usage:
      bash build.sh format
  '; local bin; bin="$(xcrun --find swift-format)"; "$bin" lint --recursive Sources Tests Tools Examples; }
sdk_analyze() { local help='
    ## Usage:
      bash build.sh analyze
  '; swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors; }
sdk_test() { local help='
    ## Usage:
      bash build.sh test
  '; local device; swift test; if [[ -d Examples/StarterIOS/StarterIOSTests ]]; then device="$(bash install.sh device_id)"; xcodebuild test -project Examples/StarterIOS/StarterIOS.xcodeproj -scheme StarterIOS -configuration Debug -destination "platform=iOS Simulator,id=$device" CODE_SIGNING_ALLOWED=NO; fi; }
sdk_docs() { local help='
    ## Usage:
      bash build.sh docs
  '; mkdir -p docs/generated; xcodebuild docbuild -scheme VModalSDK-Package -destination 'generic/platform=iOS Simulator' OTHER_SWIFT_FLAGS='-warnings-as-errors' -derivedDataPath docs/generated/DerivedData CODE_SIGNING_ALLOWED=NO; }
sdk_example_ios() { local help='
    ## Usage:
      bash build.sh example_ios
  '; xcodebuild build -project Examples/StarterIOS/StarterIOS.xcodeproj -scheme StarterIOS -destination 'generic/platform=iOS Simulator' -derivedDataPath Examples/StarterIOS/DerivedData CODE_SIGNING_ALLOWED=NO; }
# FUTURE_IPHONE_DUO_XCODE_27_1: restore when Xcode 27.1 is available in CI.
# sdk_duo_example() { local device; device="$(xcrun simctl list devices available | awk '/iPhone Duo/ {gsub(/[()]/,""); print $(NF-1); exit}')"; [[ -n "$device" ]] || return 1; xcodebuild build -project Examples/StarterIOS/StarterIOS.xcodeproj -scheme StarterIOS -destination "platform=iOS Simulator,id=$device" -derivedDataPath Examples/StarterIOS/DerivedData CODE_SIGNING_ALLOWED=NO; }
sdk_package() { local help='
    ## Usage:
      bash build.sh package
  '; local out; out="$(mktemp -d "${TMPDIR:-/tmp}/vmodal-swift.XXXXXX")"; swift run ReleaseManifest export "$sdk_dir" "$out"; (cd "$out" && swift package resolve && swift build); echo "$out"; }
sdk_build() { local help='
    ## Usage:
      bash build.sh build
  '; sdk_resolve; sdk_format; sdk_analyze; sdk_test; sdk_docs; sdk_package; sdk_example_ios; }
sdk_clean() { local help='
    ## Usage:
      bash build.sh clean
  '; [[ -f Package.swift && "$(pwd)" == *'/sdk_swift_apple' ]] || { echo 'Refusing cleanup outside VModalSDK package.' >&2; return 1; }; grep -q 'name: "VModalSDK"' Package.swift || { echo 'VModalSDK product guard failed.' >&2; return 1; }; rm -rf -- "$sdk_dir/.build" "$sdk_dir/docs/generated" "$sdk_dir/Examples/StarterIOS/DerivedData"; }
sdk_dispatch() { local help='
    ## Usage:
      bash build.sh build
  '; case "${1:-help}" in resolve) sdk_resolve;; format) sdk_format;; analyze) sdk_analyze;; test) sdk_test;; docs) sdk_docs;; example_ios) sdk_example_ios;; package) sdk_package;; build) sdk_build;; clean) sdk_clean;; help|-h|--help) echo "$help";; *) echo "Unknown command: $1" >&2; echo "$help" >&2; return 2;; esac; }
sdk_dispatch "$@"
