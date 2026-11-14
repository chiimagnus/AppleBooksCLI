#!/bin/sh
set -eu

test "$(uname -m)" = "arm64"
Tests/PackagingTests/release-metadata-smoke.sh
node scripts/check-release-order.mjs --self-test
Tests/PackagingTests/skill-smoke.sh skills/applebookscli
Tests/PackagingTests/skill-smoke.sh skills/applebookscli-zh
swift scripts/check-private-data.swift --self-test
swift scripts/check-private-data.swift --static
swift test --disable-automatic-resolution
DEBUG_CLI="$(swift build --disable-automatic-resolution --show-bin-path)/applebookscli"
[ "$("$DEBUG_CLI" --version)" = dev ]
xcrun otool -l "$DEBUG_CLI" | grep -Fq 'sectname __info_plist'
strings "$DEBUG_CLI" | grep -Fq '<key>CFBundleShortVersionString</key>'
cmp .build/checkouts/swift-argument-parser/LICENSE.txt ThirdPartyLicenses/swift-argument-parser-Apache-2.0.txt
cmp .build/checkouts/SwiftSoup/LICENSE ThirdPartyLicenses/SwiftSoup-MIT.txt
cmp .build/checkouts/ZIPFoundation/LICENSE ThirdPartyLicenses/ZIPFoundation-MIT.txt
git diff --check
