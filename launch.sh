#!/bin/bash
# Starts the media player. Works on macOS and Linux.
#   ./launch.sh              normal start (fullscreen)
#   ./launch.sh --no-fs      run in a window while testing
#   Anything else you add is passed straight to mpv.
#
# Put this file next to mediaplayer.lua, schedule.cfg and the content/ folder.

DIR="$(cd "$(dirname "$0")" && pwd)"

FULLSCREEN="--fullscreen"
EXTRA=()
for arg in "$@"; do
    if [ "$arg" = "--no-fs" ]; then FULLSCREEN=""; else EXTRA+=("$arg"); fi
done

if ! command -v mpv >/dev/null 2>&1; then
    echo "mpv is not installed. macOS: brew install mpv   Debian/Ubuntu: sudo apt install mpv" >&2
    exit 1
fi

# --no-input-default-bindings : mpv's built-in keys (q = quit, f = fullscreen,
#                               3/4 = brightness ...) would clash with your
#                               M-folder keys. Ctrl+q quits instead.
# --idle / --force-window     : keep a black window up between clips
# --keep-open=no              : lets mpv report when a clip has finished
exec mpv \
    --script="$DIR/mediaplayer.lua" \
    --script-opts=mediaplayer-root="$DIR" \
    --idle=yes --force-window=yes --keep-open=no \
    --no-input-default-bindings \
    --no-osc --osd-level=0 \
    --cursor-autohide=500 \
    $FULLSCREEN "${EXTRA[@]}"
