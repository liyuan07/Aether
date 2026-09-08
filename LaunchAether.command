#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec /bin/zsh "$PROJECT_DIR/Scripts/install-local.sh"
