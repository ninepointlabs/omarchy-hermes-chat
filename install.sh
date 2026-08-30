#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/.config/omarchy/plugins/hermes-chat"

# No symlinks, real copies — matching how nostr-signer/ring-cameras are
# installed. A symlinked directory doesn't get watched (inotify walks real
# directories, not into ~/Projects through a dir symlink); per-file symlinks
# didn't reliably work either — the target inodes live in a directory
# ~/.config/omarchy/plugins never watches, so edits to the real files in
# ~/Projects don't reliably surface as events on the watched directory.
# Copying means re-running this script is what deploys an edit — there is
# no live-symlink shortcut here.
mkdir -p "$TARGET"
cp "$DIR"/*.qml "$DIR"/manifest.json "$TARGET/"

echo "Copied $DIR/*.{qml,json} -> $TARGET/"

omarchy plugin validate "$DIR"

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
