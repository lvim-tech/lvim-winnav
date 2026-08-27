#!/usr/bin/env sh
#
# tpm's contract: on tmux start it executes the `*.tmux` files at the plugin repo's ROOT — and only
# there. This shim keeps that contract while the real tmux half lives with its own kind in tmux/.
exec "$(cd "$(dirname "$0")" && pwd)/tmux/lvim-winnav.tmux" "$@"
