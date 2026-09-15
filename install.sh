#!/usr/bin/bash
set -euo pipefail

# Fixed tool locations: this script never depends on what an earlier PATH
# entry provides, and exported shell hooks don't reach the tools it runs.
PATH=/usr/bin:/bin
export PATH
unset BASH_ENV ENV CDPATH GLOBIGNORE
OMARCHY=/usr/share/omarchy/bin/omarchy
if [ ! -x "$OMARCHY" ]; then
  echo "Error: $OMARCHY not found; this installer is for Omarchy." >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$HOME/.config/omarchy/plugins"
TARGET="$PARENT/hermes-chat"

# No symlinks, real copies — matching how nostr-signer/ring-cameras are
# installed. A symlinked directory doesn't get watched (inotify walks real
# directories, not into ~/Projects through a dir symlink); per-file symlinks
# didn't reliably work either. Copying means re-running this script is what
# deploys an edit — there is no live-symlink shortcut here.
mkdir -p "$PARENT"

# Reject a symlinked destination outright rather than following it — a
# symlink planted at $TARGET would otherwise make the copy write through to
# wherever it points instead of the real plugin directory.
if [ -L "$TARGET" ]; then
  echo "Error: $TARGET is a symlink, not a plugin directory. Remove it and re-run this script." >&2
  exit 1
fi

# Build the full install in a scratch directory next to $TARGET (same
# filesystem, so the swap below is a rename) and validate THAT — never the
# live install — so a validation failure can never leave $TARGET half
# overwritten. `install` copies file contents with explicit modes.
STAGE="$(mktemp -d "$PARENT/.hermes-chat.staging.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
for file in "$DIR"/*.qml "$DIR"/Hermes.js "$DIR"/manifest.json; do
  install -m 0644 "$file" "$STAGE/"
done
install -d -m 0755 "$STAGE/bin"
for helper in bounded-run hermes-verify hermes-state; do
  install -m 0755 "$DIR/bin/$helper" "$STAGE/bin/$helper"
done
"$OMARCHY" plugin validate "$STAGE"

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

echo "Installed $DIR -> $TARGET/"

if "$OMARCHY" bar put tim.hermes-chat; then
  echo "Added the Hermes Chat widget to your bar (right section)."
else
  echo "Could not auto-add it to the bar; add it yourself with:"
  echo "  omarchy bar put tim.hermes-chat"
fi

# Confirmed by direct testing on this machine: neither the plugins-dir
# inotify watcher NOR the `shell rescanPlugins` IPC call reliably force
# Quickshell to recompile a changed QML file. A full shell restart is the
# only thing that was observed to actually pick up an edit. This restarts
# just the Omarchy shell chrome (bar/panels) — other running apps are
# unaffected.
"$OMARCHY" restart shell
echo "Restarted the Omarchy shell so this change is actually live (rescanPlugins alone was not enough on this machine)."
