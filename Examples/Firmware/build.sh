#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PIO_BOARD="${1:-pico2}"
case "$PIO_BOARD" in pico|pico2) ;; *) echo "Usage: bash build.sh [pico|pico2]" >&2; exit 2 ;; esac
export BOARD="$PIO_BOARD"
export BUILD_SCRIPT_VERSION=1
export BUILD_TYPE=RelWithDebInfo
export SWIFTLY_PATH="${SWIFTLY_PATH:-$HOME/.swiftly/bin/swiftly}"
export PREPARATION_SCRIPT_PATH="$PWD/.build/env-$PIO_BOARD.sh"
mkdir -p .build
"$SWIFTLY_PATH" run +main-snapshot-2026-04-27 swift package \
    --allow-writing-to-package-directory --allow-network-connections all \
    prepare-rp2xxx-environment --dump-prep-script "$PREPARATION_SCRIPT_PATH" \
    --disable-vscode-settings --disable-sourcekit-lsp-settings --disable-swift-version
source "$PREPARATION_SCRIPT_PATH"
"$SWIFTLY_PATH" run +main-snapshot-2026-04-27 swift build \
    --build-system native --configuration "$SWIFT_BUILD_TYPE" \
    --toolset "$TOOLSET_PATH" --triple "$SWIFTPM_TRIPLE" $EXTRA_CONFIG_PARAMS
finalize_rp2xxx_binary
# Intentionally no flashing, probing, or device communication.
