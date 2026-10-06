#!/bin/sh
# Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -x "$project_dir/.build/toolchain/cargo/bin/cargo" ]; then
    export RUSTUP_HOME="$project_dir/.build/toolchain/rustup"
    export CARGO_HOME="$project_dir/.build/toolchain/cargo"
    export PATH="$CARGO_HOME/bin:$PATH"
else
    export PATH="${HOME}/.cargo/bin:$PATH"
fi
command -v cargo >/dev/null 2>&1 || { echo 'Rust 1.90.0 required; install rustup before building Aether.' >&2; exit 1; }
cd "$project_dir/Rust/AetherCore"
export CARGO_TARGET_DIR="$project_dir/.build/rust"
# The C ABI library is linked into both SwiftPM tests and the app; no runtime loader.
archs=${ARCHS:-$(uname -m)}
mkdir -p "$CARGO_TARGET_DIR/lib"
if [ "${1:-}" = test ]; then exec cargo test --locked; fi
for arch in $archs; do
    case "$arch" in
        arm64) target=aarch64-apple-darwin ;;
        x86_64) target=x86_64-apple-darwin ;;
        *) echo "Unsupported Rust architecture: $arch" >&2; exit 1 ;;
    esac
    cargo build --locked --release --target "$target"
done
# Paths are repo-local and may contain spaces: collect via positional arguments.
set --
for arch in $archs; do
    case "$arch" in arm64) target=aarch64-apple-darwin ;; x86_64) target=x86_64-apple-darwin ;; esac
    set -- "$@" "$CARGO_TARGET_DIR/$target/release/libaether_core.a"
done
temporary=$(mktemp "$CARGO_TARGET_DIR/lib/core.XXXXXX")
trap 'rm -f "$temporary"' EXIT
lipo -create "$@" -output "$temporary"
mv "$temporary" "$CARGO_TARGET_DIR/lib/libaether_core.a"
