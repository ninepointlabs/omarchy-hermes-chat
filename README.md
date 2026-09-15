# Hermes Chat (Omarchy plugin)

![Hermes Chat preview](preview.png)

A bar icon for the Omarchy shell (Quickshell) that lets you send a quick
message to your local [Hermes](https://github.com/NousResearch/hermes-agent)
agent from the dropdown, without opening the desktop app.

This is a shell plugin, not a Hermes desktop-app plugin — it runs your
locally installed Hermes agent directly. It works whether or not the Hermes
Electron app is open, and does **not** require the persistent gateway
(`hermes gateway run`) to be running.

## What it does

- **Bar icon** — a small chat-bubble mark; turns to your bar's urgent color
  if the Hermes install can't be verified (see [Security model](#security-model)).
- **Optional keyboard shortcut** — toggle the dropdown without touching the
  mouse. Not wired automatically; see [Optional: keyboard
  shortcut](#optional-keyboard-shortcut) below.
- **Quick chat** — type a message, hit Enter (or click Send). It runs
  `hermes chat -Q --oneshot --query-file - -c` (one-shot mode, message on
  stdin, continuing your most recently active Hermes conversation) and shows
  the reply inline. One-shot turns can take anywhere from a few seconds to
  tens of seconds — the panel shows "Thinking…" and a Stop button.
- **New chat** — the next message you send starts a fresh conversation
  (drops `-c`) instead of continuing the latest one.
- **Show full desktop app** — focuses the Hermes window if it's already
  open (`hyprctl dispatch focuswindow`), or launches it
  (`hermes desktop --skip-build`) through the same verified path as chat.
- **Notify me on answers** — a toggle, persisted (along with your recent
  conversation) to `~/.local/state/omarchy/hermes-chat/state.json`. When
  on, you get a notification that a reply arrived, but only if the dropdown
  was closed at the time. The notification doesn't include the reply text,
  so model output never appears on a command line.

## Dependencies

- **`hermes-agent`, installed with pacman** (it lives in `/opt/hermes-agent`).
  Hermes Chat runs only that packaged install, and only while it matches
  pacman's record of the package. A `hermes` from `pip`, `uv`, a git checkout,
  or anywhere else on `PATH` is not used.
- `python3` (standard library only) at `/usr/bin/python3`, for the plugin's
  small helpers in `bin/`.
- Optional, standard on Omarchy: `hyprctl` and `pgrep` for "Show full desktop
  app", `notify-send` for reply notifications — each used from `/usr/bin`
  only; if one is missing, that feature does nothing.

No shell is involved at runtime.

## Security model

Everything the plugin runs is an argument list whose first element is a
fixed absolute path, built in `Hermes.js`. Nothing is looked up on `PATH`,
nothing goes through `bash -c`, and every `Process` clears the shell's
environment and gets only a fixed `PATH=/usr/bin:/bin` plus a short
allow-list of session variables (locale, XDG directories, and for the
desktop app/notifications the Wayland/D-Bus/Hyprland handles), each refused
unless it is a bounded single-line value. `BASH_ENV`, `ENV`, `LD_PRELOAD`,
`PYTHONPATH`/`PYTHONSTARTUP` and the like never reach anything the plugin
starts, and the helpers run under `/usr/bin/python3 -I -S -B`, which
ignores `PYTHON*` variables and the user site directory anyway.

**Process supervision — `bin/bounded-run`.** Every command runs under this
supervisor: at most 256 KiB of stdout / 64 KiB of stderr for chat (smaller
caps for everything else) ever reach the shell; the first byte past a cap
stops the job (exit 201 / 202); a hard deadline backs up the panel's own
300 s limit (exit 124). The job gets its own session, and the supervisor
stays its direct parent and a child subreaper, so it can signal the job's
process group only while that PID/PGID is still provably its own, and it
reaps every descendant before exiting. Stop, the deadline, and panel teardown
all send TERM to the supervisor, which escalates TERM → KILL across the whole
tree. If the supervisor itself is killed outright, the job dies with it
(parent-death signal).

**Hermes provenance — `bin/hermes-verify`.** Immediately before every chat
message (and before launching the desktop app), in the same process that then
starts Hermes, it checks:

- there is exactly one pacman package named `hermes-agent`, and its database
  entry (`desc`, `mtree`, `files`) and every directory above it are root-owned
  and not group/other writable;
- every entry in the package's mtree still matches: file type, root
  ownership, exact mode, size, symlink target, and the full SHA-256 of every
  file;
- the interpreter the package's venv links to (`/usr/bin/python3.11`) belongs
  to one of the package's declared dependencies (`python311`), whose mtree is
  verified the same way;
- nothing importable was added: no entry in `/opt/hermes-agent` or the
  interpreter's standard library that the packages don't list (root-owned
  `__pycache__/*.pyc` excepted), and the venv doesn't include system
  site-packages;
- every directory above the install, the interpreter and the package
  database is root-owned and not writable by others — so nothing running as
  you can change any of it between the check and the exec;
- the installed version is one this plugin release was tested with
  (`0.21.0-1`), or one you approved in the panel. An approval is stored as
  `VERSION@SHA256(package mtree)`, so it covers exactly that package build;
  a rebuild or update asks again.

Only then does it exec `/opt/hermes-agent/venv/bin/python -I -B -m
hermes_cli.main` directly — not the `/usr/bin/hermes` launcher script — with a
minimal environment: `HOME`/`USER` from the password database, the fixed
`PATH`, `HERMES_DISABLE_LAZY_INSTALLS=1`, and no `HERMES_LAZY_INSTALL_TARGET`
(so Hermes can't pip-install into, or import from, a directory under your
home). Any mismatch fails closed: the panel says what differed and doesn't
start Hermes. `pacman -Qkk hermes-agent` shows the same differences.

What this can't cover: Hermes reads its own configuration, credentials
(`~/.hermes/.env`), skills, plugins and hooks from `~/.hermes`, and its tools
run other programs (`node`, `rg`, …). Those are Hermes' own behavior under
your account, outside anything this plugin can pin; Hermes asks before
running unapproved config hooks, and this plugin never passes
`--accept-hooks` or `--yolo`.

**State file — `bin/hermes-state`.** The transcript and preferences are read
and written only over the helper's stdin/stdout, never argv or environment.
It opens every directory from `/` down to
`~/.local/state/omarchy/hermes-chat` with `O_NOFOLLOW` relative to the held
descriptor of its parent, checks each one's owner and permissions, creates
missing ones `0700`, and then works only through the held descriptor for the
state directory. Reads refuse anything but your own private regular file of at
most 1 MiB; writes go to a randomly named `O_EXCL` `0600` file in that
directory, are fsynced, and are renamed over `state.json` — a symlink, FIFO,
directory or foreign file at that name is refused, not followed or replaced.

## Why "continue the latest chat" instead of "the focused session"

A GUI concept like "the session you have focused in the desktop app" isn't
visible to a shell plugin outside that app — there's no shared API between
Quickshell and the Electron renderer. `hermes chat -c` (continue the most
recent session) is the closest real equivalent the CLI exposes, and it's
what you get by default; "New chat" is there for when you explicitly want a
clean slate.

## Install

```bash
./install.sh
```

This copies the plugin's files into `~/.config/omarchy/plugins/hermes-chat`,
runs `omarchy bar put tim.hermes-chat` to add the icon to the right section
of your bar, then runs `omarchy restart shell`.

**Re-run `./install.sh` after every edit.** Files are copied, not
symlinked — there's no live-reload shortcut here. On this machine neither the
plugins-dir file watcher nor the `omarchy-shell shell rescanPlugins` IPC call
reliably picked up a changed file — only a full `omarchy restart shell` was
observed to actually reload it, so that's what this script does every time.
It only restarts the shell chrome (bar/panels); other running apps are
unaffected.

If you ever want to move it, remove it from the bar, or re-add it:

```bash
omarchy bar move tim.hermes-chat --section left   # move it
omarchy bar put tim.hermes-chat --before omarchy.tray
omarchy plugin disable tim.hermes-chat            # take it off the bar
omarchy plugin enable tim.hermes-chat             # put it back
```

## Optional: keyboard shortcut

Not set up by `install.sh` — it edits your Hyprland config, which felt
like the wrong thing to do without asking. To toggle the dropdown with a
key combo instead of clicking the bar icon, add a line like this to
`~/.config/hypr/bindings.lua` (pick any combo `omarchy menu keybindings
--print` doesn't already list):

```lua
o.bind("SUPER + H", "Hermes chat", "omarchy-shell shell toggle tim.hermes-chat")
```

Then run `hyprctl reload`.

## Uninstall

```bash
omarchy plugin disable tim.hermes-chat
rm -rf ~/.config/omarchy/plugins/hermes-chat
rm -rf ~/.local/state/omarchy/hermes-chat   # drops the conversation/notify state too
```

If you set up the optional keybind above, remove that line from
`~/.config/hypr/bindings.lua` and run `hyprctl reload` — otherwise it just
no-ops harmlessly once the plugin is gone.

## Tests

```bash
./tests/run
```

- `tests/test_hermes_state.py` — symlinks at `state.json` and at every
  directory component, a symlinked home, FIFOs, oversized files and payloads,
  loose permissions, foreign ownership, hard links, a directory swapped out
  from under a held descriptor, and concurrent writers.
- `tests/test_hermes_verify.py` — a fake pacman-installed tree: tampered
  contents, sizes, modes and symlinks, added modules and `.pth` files,
  writable directories and ancestors, foreign owners, escaped mtree names,
  version approvals bound to the package build, and the minimal environment.
- `tests/hermes-js.test.cjs` — every command starts with the fixed isolated
  interpreter, never a shell; the message is never in argv; environment and
  verifier output are sanitized; every `Process` in `Panel.qml` clears its
  environment.
- `tests/bounded-run.test.sh` and `tests/bounded-run-race.py` — caps,
  deadlines, TERM-ignoring and escaped descendants, parent and supervisor
  death, and a harness that checks no signal ever reaches a process group the
  supervisor doesn't provably own.
- `tests/shadow-proof.sh` — runs the real commands with a hostile `PATH`,
  `BASH_ENV`, `ENV`, `PYTHONPATH`, `PYTHONSTARTUP` and `LD_PRELOAD` and checks
  none of the planted programs or hooks ran.

## Notes for future changes

Built against the Omarchy shell's actual plugin contract, read straight out
of `/usr/share/omarchy/shell` (not guessed): `services/PluginRegistry.qml`
for the manifest schema and enable/bar-layout rules; `Ui/Panel.qml`,
`Ui/KeyboardPanel.qml`, `Ui/BarIconButton.qml`, `Ui/Button.qml`,
`Ui/TextField.qml`, `Ui/Toggle.qml`, and `Ui/PanelHero.qml` for the widget
base classes and controls this plugin builds on. `omarchy plugin validate
<folder>` (ships with Omarchy) checks the manifest against the current schema
if something breaks later.

When testing a new hermes-agent release, add its version to
`TESTED_VERSIONS` in `bin/hermes-verify`.

## License

MIT — see [LICENSE](LICENSE).
