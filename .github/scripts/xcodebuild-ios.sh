#!/usr/bin/env bash
# Unsigned device build of the AI Gaming Coach app + broadcast extension.
# Prints only errors/warnings from our own sources and fails on either.
set -euo pipefail
xcodebuild build \
  -project AIGamingCoach.xcodeproj \
  -scheme AIGamingCoach \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  > xcodebuild.log 2>&1 || { grep -E "error:" xcodebuild.log | sort -u; tail -40 xcodebuild.log; exit 1; }
grep -q "BUILD SUCCEEDED" xcodebuild.log
own=$(grep -E "^$PWD/(App|Shared|BroadcastExtension|Packages)/.*(warning|error):" xcodebuild.log | sort -u || true)
if [ -n "$own" ]; then
  echo "$own"
  echo "::error::Build produced warnings in project sources."
  exit 1
fi
echo "BUILD SUCCEEDED with no warnings in project sources."
