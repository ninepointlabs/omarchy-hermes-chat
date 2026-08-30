import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon + dropdown for talking to the local `hermes` CLI without opening
// the Hermes desktop app. Each send runs `hermes -z "<text>"` (one-shot
// mode) as its own child process — there is no daemon here, matching the
// CLI's own model where a one-shot turn doesn't require the persistent
// gateway. `-c`/`--continue` is added on every send except the one right
// after "New chat", so quick chat naturally continues whatever Hermes
// conversation is currently most recent (there's no way for a plugin
// outside the desktop app to know which *GUI* session has focus, so
// "most recent" is the closest available stand-in).
//
// One-shot turns can take anywhere from a few seconds to tens of seconds
// (model + tool-loop latency) — the panel shows a busy state and lets you
// keep using the rest of your desktop while it runs.
Panel {
  id: root
  moduleName: "tim.hermes-chat"
  ipcTarget: "tim.hermes-chat"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  // Quickshell instantiates this whole component once PER MONITOR (a bar
  // surface is built per screen), so root.transcript etc. are otherwise
  // separate, unsynced copies of state per screen. Persisting to this file
  // and re-reading it every time the panel opens is what makes "whichever
  // monitor you open it on" show the same conversation.
  readonly property string statePath: root.home + "/.local/state/omarchy/hermes-chat/state.json"
  readonly property string legacyNotifyPath: root.home + "/.local/state/omarchy/hermes-chat/notify"

  property bool hermesAvailable: true
  property bool busy: false
  property bool freshChatPending: false
  property string draft: ""
  property string errorText: ""
  property bool notifyOnAnswers: false
  property var transcript: [] // [{ role: "user"|"assistant", text }]
  property string _stdout: ""
  property string _stderr: ""
  // Resolved once at startup to absolute paths (falls back to the bare name
  // if resolution fails) so command spawning doesn't trust whatever
  // happens to be first on $PATH — matches nostr-signer's convention of
  // pinning an absolute binary path rather than relying on PATH lookup.
  property var bin: ({
    hermes: "hermes", bash: "bash", notifySend: "notify-send",
    hyprctl: "hyprctl", pgrep: "pgrep", setsid: "setsid"
  })
  readonly property int maxReplyChars: 4000

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: !hermesAvailable ? urgent : foreground

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function resolveBinaries() {
    // `command -v` falls back to echoing the bare name itself when a
    // binary isn't found, so this always emits exactly 6 lines.
    resolveBinsProcess.command = ["bash", "-c",
      "for b in hermes bash notify-send hyprctl pgrep setsid; do command -v \"$b\" 2>/dev/null || echo \"$b\"; done"
    ]
    resolveBinsProcess.running = true
  }

  function applyResolvedBinaries(text) {
    var lines = String(text || "").trim().split("\n")
    if (lines.length === 6) {
      root.bin = {
        hermes: lines[0], bash: lines[1], notifySend: lines[2],
        hyprctl: lines[3], pgrep: lines[4], setsid: lines[5]
      }
    } // else: resolution failed oddly; keep the bare-name fallbacks
    root.checkHermesAvailable()
    root.readState()
  }

  function checkHermesAvailable() {
    versionProcess.command = [root.bin.hermes, "--version"]
    versionProcess.running = true
  }

  // Reads state.json if present; otherwise seeds notifyOnAnswers from the
  // old single-purpose prefs file so upgrading from an earlier version of
  // this plugin doesn't silently reset a preference you already set.
  // `head -c` caps how much JSON.parse ever has to look at, regardless of
  // how large the file on disk is.
  function readState() {
    stateReadProcess.command = [root.bin.bash, "-c",
      "if [ -f \"$0\" ]; then head -c 1048576 \"$0\"; " +
      "elif [ \"$(cat \"$1\" 2>/dev/null)\" = \"1\" ]; then printf '{\"notifyOnAnswers\":true}'; " +
      "else printf '{}'; fi",
      root.statePath, root.legacyNotifyPath
    ]
    stateReadProcess.running = true
  }

  function writeState() {
    var payload = JSON.stringify({
      transcript: root.transcript,
      freshChatPending: root.freshChatPending,
      notifyOnAnswers: root.notifyOnAnswers
    })
    // chmod 700/600: this file accumulates real conversation content, so it
    // shouldn't inherit the default (often group/world-readable) umask.
    stateWriteProcess.command = [root.bin.bash, "-c",
      "d=\"$(dirname \"$0\")\" && mkdir -p \"$d\" && chmod 700 \"$d\" && " +
      "printf '%s' \"$1\" > \"$0\" && chmod 600 \"$0\"",
      root.statePath, payload
    ]
    stateWriteProcess.running = true
  }

  function applyState(text) {
    var parsed = {}
    try { parsed = JSON.parse(text || "{}") || {} } catch (e) { parsed = {} }
    root.transcript = Array.isArray(parsed.transcript) ? parsed.transcript : []
    root.freshChatPending = !!parsed.freshChatPending
    root.notifyOnAnswers = !!parsed.notifyOnAnswers
    root.scrollToLatest()
  }

  function appendTranscript(entry) {
    // Cap history so the state file (re-read on every open) can't grow
    // without bound over weeks of quick-chat use.
    root.transcript = root.transcript.concat([entry]).slice(-20)
    root.scrollToLatest()
  }

  // Jumps the transcript scroll area to the newest message. Qt.callLater
  // defers this past the Repeater/Column relayout that follows a
  // transcript change, so contentHeight is already current when this runs
  // — calling it synchronously would scroll to where the *old* content
  // ended, one message behind.
  function scrollToLatest() {
    Qt.callLater(function() {
      transcriptFlick.contentY = Math.max(0, transcriptFlick.contentHeight - transcriptFlick.height)
    })
  }

  function setNotifyPref(value) {
    root.notifyOnAnswers = value
    root.writeState()
  }

  function sendMessage() {
    var text = root.draft.trim()
    if (!text || root.busy) return

    root.errorText = ""
    root.appendTranscript({ role: "user", text: text })
    root.draft = ""

    var args = [root.bin.hermes, "-z", text]
    if (!root.freshChatPending) args.push("-c")
    root.freshChatPending = false
    root.writeState()

    root.busy = true
    root._stdout = ""
    root._stderr = ""
    chatProcess.command = args
    chatProcess.running = true
  }

  function newChat() {
    root.freshChatPending = true
    root.transcript = []
    root.errorText = ""
    root.writeState()
  }

  function showFullApp() {
    haptic()
    focusProcess.command = [root.bin.bash, "-c",
      "if \"$0\" -f 'apps/desktop/release/linux-unpacked/Hermes$' >/dev/null 2>&1; then " +
      "\"$1\" dispatch focuswindow 'class:^(Hermes)$' >/dev/null 2>&1; " +
      "else \"$2\" -f \"$3\" desktop --skip-build >/dev/null 2>&1; fi",
      root.bin.pgrep, root.bin.hyprctl, root.bin.setsid, root.bin.hermes
    ]
    focusProcess.running = true
    root.close()
  }

  // No haptics service is wired into this base kit the way the Hermes
  // desktop SDK has one — left as a no-op seam so it's obvious where one
  // would plug in if this shell grows a haptics/sound hook later.
  function haptic() {}

  // Re-read on every open (not just once at startup) so switching monitors
  // — a genuinely different component instance — picks up whatever the
  // last-used monitor's instance wrote.
  onOpenedChanged: if (opened) { root.errorText = ""; root.readState() }

  Component.onCompleted: root.resolveBinaries()

  Process {
    id: resolveBinsProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: resolveBinsStdout
      waitForEnd: true
      onStreamFinished: root.applyResolvedBinaries(text)
    }
  }

  Process {
    id: versionProcess
    running: false
    command: []
    onExited: function(exitCode) { root.hermesAvailable = (exitCode === 0) }
  }

  Process {
    id: stateReadProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: stateReadStdout
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
  }

  Process {
    id: stateWriteProcess
    running: false
    command: []
  }

  Process {
    id: focusProcess
    running: false
    command: []
  }

  Process {
    id: chatProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: chatStdout
      waitForEnd: true
      onStreamFinished: root._stdout = text
    }
    stderr: StdioCollector {
      id: chatStderr
      waitForEnd: true
      onStreamFinished: root._stderr = text
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode === 0) {
        var full = root._stdout.trim() || "(empty response)"
        var reply = full.length > root.maxReplyChars
          ? full.slice(0, root.maxReplyChars) + "… [truncated]"
          : full
        root.appendTranscript({ role: "assistant", text: reply })
        root.writeState()
        if (root.notifyOnAnswers && !root.opened) {
          notifyProcess.command = [root.bin.notifySend, "-a", "Hermes", "Hermes replied", reply.slice(0, 200)]
          notifyProcess.running = true
        }
      } else {
        root.errorText = root._stderr.trim() || ("hermes exited with code " + exitCode)
      }
    }
  }

  Process {
    id: notifyProcess
    running: false
    command: []
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        ChatIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
        }
      }
    }
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // Land keyboard focus straight in the composer so SUPER+H (or clicking
    // the chip) can be followed immediately by typing, no extra click/Tab.
    // Falls back to escCatcher (which still catches Escape regardless of
    // where focus lands, since Qt Quick bubbles unhandled key events up the
    // parent chain) when the field isn't showing, e.g. hermes CLI missing.
    focusTarget: root.hermesAvailable ? draftField : escCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Full natural height (header + every transcript line + footer) is what
    // the panel WOULD be with no internal scrolling; fittedContentHeight
    // caps it at 520px. When it's under the cap, transcriptFlick ends up
    // exactly as tall as its content and never scrolls — same look as
    // before this changed. When it's over, the footer (composer + quick
    // actions) still gets its full natural height since it's bottom-anchored
    // outside the scroll area, and transcriptFlick absorbs the deficit.
    contentHeight: panel.fittedContentHeight(
      topSection.implicitHeight + Style.space(12) + transcriptColumn.implicitHeight + Style.space(12) + bottomSection.implicitHeight,
      Style.space(520)
    )

    Item {
      id: escCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      Column {
        id: topSection
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Hermes"
          meta: !root.hermesAvailable ? "hermes CLI not found on PATH"
            : root.busy ? "Thinking…"
            : "Ready"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          text: root.errorText
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // --- hermes CLI missing --------------------------------------------
        Column {
          visible: !root.hermesAvailable
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: "The `hermes` command isn't on PATH for this shell, so quick chat can't run. Open a terminal and run `hermes doctor` to check your install."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            text: "Re-check"
            foreground: root.foreground
            bordered: true
            onClicked: root.checkHermesAvailable()
          }
        }
      }

      // --- transcript — the only scrolling region. Pinned between
      // topSection and bottomSection so the composer below is never
      // scrolled out of view, however long the conversation gets.
      Flickable {
        id: transcriptFlick
        anchors.top: topSection.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: bottomSection.top
        anchors.bottomMargin: Style.space(12)
        contentWidth: width
        contentHeight: transcriptColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: transcriptColumn
          visible: root.hermesAvailable && root.transcript.length > 0
          width: transcriptFlick.width
          spacing: Style.space(8)

          Repeater {
            model: root.transcript
            delegate: Column {
              required property var modelData
              width: transcriptColumn.width
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: modelData.role === "user" ? "You" : "Hermes"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                width: parent.width
                // Plain text, deliberately: this renders your own typed
                // messages AND the model's replies. AutoText's default
                // markup-sniffing could otherwise turn adversarial-looking
                // content (a stray <img>/<a> the model echoes) into a live
                // rendered link or image fetch instead of inert text.
                text: modelData.text
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      // --- composer + quick actions — fixed to the bottom, always visible.
      Column {
        id: bottomSection
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        Column {
          visible: root.hermesAvailable
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: draftField
            width: parent.width
            enabled: !root.busy
            placeholderText: root.freshChatPending ? "Start a new chat…" : "Continue your latest chat…"
            foreground: root.foreground
            text: root.draft
            onTextChanged: root.draft = text
            Keys.onReturnPressed: root.sendMessage()
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: root.busy ? "Thinking…" : "Send"
              foreground: root.foreground
              bordered: true
              enabled: !root.busy && root.draft.trim().length > 0
              onClicked: root.sendMessage()
            }

            Button {
              visible: root.busy
              text: "Stop"
              foreground: root.urgent
              bordered: true
              onClicked: chatProcess.running = false
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(8)

          Row {
            spacing: Style.space(6)

            Button {
              text: "New chat"
              foreground: root.foreground
              bordered: true
              onClicked: root.newChat()
            }

            Button {
              text: "Show full desktop app"
              foreground: root.foreground
              bordered: true
              onClicked: root.showFullApp()
            }
          }

          Toggle {
            width: parent.width
            label: "Notify me on answers"
            description: "Native notification when a reply lands while this dropdown is closed."
            checked: root.notifyOnAnswers
            foreground: root.foreground
            onClicked: root.setNotifyPref(!root.notifyOnAnswers)
          }
        }
      }
    }
  }
}
