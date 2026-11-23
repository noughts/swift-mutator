#!/bin/bash
# Publishes the Apple silicon binary of the current origin/main as GitHub release v<version>.
#
#   scripts/release.sh 0.2.0
#
# <version> must equal `toolVersion` (Sources/MutatorCLI/Options.swift). Run it on an Apple silicon
# Mac, from a clean checkout of main that matches origin/main: the tag is created at HEAD.
set -euo pipefail

version="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
    echo "release: the working tree has changes" >&2
    exit 1
fi
git fetch -q origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "release: HEAD is not origin/main" >&2
    exit 1
fi

swift build -c release
binary="$(swift build -c release --show-bin-path)/swift-mutator"
if [ "$(lipo -archs "$binary")" != "arm64" ]; then
    echo "release: $binary is not an arm64 binary" >&2
    exit 1
fi
if [ "$("$binary" --version)" != "$version" ]; then
    echo "release: the binary is version $("$binary" --version), not $version" >&2
    exit 1
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
asset="swift-mutator-$version-macos-arm64.tar.gz"
tar -czf "$out/$asset" -C "$(dirname "$binary")" swift-mutator
sha256="$(shasum -a 256 "$out/$asset" | cut -d ' ' -f 1)"
url="https://github.com/noughts/swift-mutator/releases/download/v$version/$asset"

notes="$(cat <<EOF
Apple silicon (arm64), macOS 13 or later.

\`\`\`bash
curl -fsSL $url | tar -xz
\`\`\`

This extracts \`swift-mutator\` into the current directory; move it to a directory on your PATH.

SHA-256 of \`$asset\`: \`$sha256\`
EOF
)"

gh release create "v$version" "$out/$asset" --target "$(git rev-parse HEAD)" --title "v$version" --notes "$notes"
echo "release: published v$version ($asset, sha256 $sha256)"
