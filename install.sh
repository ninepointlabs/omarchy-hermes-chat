#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$HOME/.config/omarchy/plugins"
TARGET="$PARENT/hermes-chat"

# No symlinks, real copies — matching how nostr-signer/ring-cameras are
# installed. A symlinked directory doesn't get watched (inotify walks real
# directories, not into ~/Projects through a dir symlink); per-file symlinks
# didn't reliably work either — the target inodes live in a directory
# ~/.config/omarchy/plugins never watches, so edits to the real files in
# ~/Projects don't reliably surface as events on the watched directory.
# Copying means re-running this script is what deploys an edit — there is
# no live-symlink shortcut here.
mkdir -p "$PARENT"

# Reject a symlinked destination outright rather than following it — a
# symlink planted at $TARGET (by another process, or left over from a manual
# install) would otherwise make `cp` write through to wherever it points
# instead of the real plugin directory.
if [ -L "$TARGET" ]; then
  echo "Error: $TARGET is a symlink, not a plugin directory. Remove it and re-run this script." >&2
  exit 1
fi

# Build the full install in a scratch directory next to $TARGET (same
# filesystem, so the swap below is a rename) and validate THAT — never the
# live install — so a validation failure can never leave $TARGET half
# overwritten.
STAGE="$(mktemp -d "$PARENT/.hermes-chat.staging.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$DIR"/*.qml "$DIR"/manifest.json "$STAGE/"
omarchy plugin validate "$STAGE"

# Atomic swap: move the old install aside, rename the validated stage into
# place, then drop the old copy. If the second rename fails partway, the old
# install is put back instead of leaving $TARGET missing or mixed.
if [ -e "$TARGET" ]; then
  OLD="$PARENT/.hermes-chat.old.$$"
  mv -f "$TARGET" "$OLD"
  if mv -f "$STAGE" "$TARGET"; then
    rm -rf "$OLD"
  else
    rm -rf "$TARGET" 2>/dev/null || true
    mv -f "$OLD" "$TARGET"
    echo "Error: install failed; restored the previous install." >&2
    exit 1
  fi
else
  mv -f "$STAGE" "$TARGET"
fi
trap - EXIT

echo "Installed $DIR/*.{qml,json} -> $TARGET/"

if omarchy bar put tim.hermes-chat; then
  echo "Added the Hermes Chat widget to your bar (right section)."
else
  echo "Could not auto-add it to the bar; add it yourself with:"
  echo "  omarchy bar put tim.hermes-chat"
fi

# Confirmed by direct testing on this machine: neither the plugins-dir
# inotify watcher NOR the `shell rescanPlugins` IPC call reliably force
# Quickshell to recompile a changed QML file — both claim to reload but the
# old bytecode keeps running. A full shell restart is the only thing that
# was observed to actually pick up an edit. This restarts just the Omarchy
# shell chrome (bar/panels) — other running apps are unaffected.
omarchy restart shell
echo "Restarted the Omarchy shell so this change is actually live (rescanPlugins alone was not enough on this machine)."
