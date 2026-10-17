import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon + dropdown for talking to the local `hermes` CLI without opening
// the Hermes desktop app. Each send runs `hermes chat -Q --oneshot
// --query-file -` (one-shot mode, message piped over stdin rather than
// argv) as its own child process, in its own process group — there is no
// daemon here, matching the CLI's own model where a one-shot turn doesn't
// require the persistent gateway. `-c`/`--continue` is added on every send
// except the one right after "New chat", so quick chat naturally continues
// whatever Hermes conversation is currently most recent (there's no way for
// a plugin outside the desktop app to know which *GUI* session has focus,
// so "most recent" is the closest available stand-in).
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
  // Latest state payload waiting for stateWriteProcess to be free (see
  // flushState()); only the newest matters, so later writes replace it.
  property string _pendingState: ""
  // Resolved once at startup to absolute paths (falls back to the bare name
  // if resolution fails) so command spawning doesn't trust whatever
  // happens to be first on $PATH — matches nostr-signer's convention of
  // pinning an absolute binary path rather than relying on PATH lookup.
  property var bin: ({
    hermes: "hermes", bash: "bash", notifySend: "notify-send",
    hyprctl: "hyprctl", pgrep: "pgrep", setsid: "setsid"
  })
  readonly property int maxReplyChars: 4000
  // Byte caps on the chat subprocess's stdout/stderr, enforced *producer
  // side* in the wrapper script below (see sendMessage()): each stream is
  // piped through `head -c` in the spawned shell, so at most this many bytes
  // ever reach Quickshell's StdioCollector, regardless of how much or how
  // fast the job writes. The first byte past the cap kills the whole job's
  // process group and makes the wrapper exit with a distinct status
  // (excessStdoutExit / excessStderrExit) so the panel can say why.
  readonly property int maxStdoutBytes: 262144
  readonly property int maxStderrBytes: 65536
  readonly property int excessStdoutExit: 201
  readonly property int excessStderrExit: 202
  // Soft deadline passed to `hermes --run-budget`: the agent gets a wrap-up
  // nudge at 80% elapsed and tries to land a response before this. The hard
  // deadline below is the actual enforcement — this just makes a clean
  // finish more likely before that kicks in.
  readonly property int chatRunBudgetSeconds: 240
  // Hard local deadline: if the job hasn't exited by here, it's killed
  // regardless of what --run-budget did or didn't manage on its own.
  readonly property int chatHardTimeoutSeconds: 300
  // Grace window between TERM and KILL when stopping a chat job — same
  // window the process-group wrapper below uses internally.
  readonly property int killGraceSeconds: 3
  // Set right before killChatProcess() signals the job, so onExited can show
  // *why* it ended instead of a bare "hermes exited with code N".
  property string _killReason: ""
  // The About page replaces the chat inside the same dropdown.
  property bool showAbout: false

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
    root._pendingState = JSON.stringify({
      transcript: root.transcript,
      freshChatPending: root.freshChatPending,
      notifyOnAnswers: root.notifyOnAnswers
    })
    root.flushState()
  }

  // Starts the writer for whatever payload is pending, unless one is already
  // in flight — in which case stateWriteProcess.onExited calls back here.
  // Quickshell ignores `command` changes while a Process is running and
  // write() goes to the *current* process, so without this guard two quick
  // writes would push the second payload into the first writer's stdin.
  function flushState() {
    if (stateWriteProcess.running || !root._pendingState) return
    var payload = root._pendingState
    root._pendingState = ""
    // The payload — which is the whole conversation transcript — is piped
    // to the writer over stdin, never passed as an argv value, so prompts
    // and model output don't sit in /proc/<pid>/cmdline for the life of the
    // write. The only argv is the (non-secret) destination path.
    //
    // Write via a same-directory temp file + rename rather than a direct
    // `> "$0"` redirect: a redirect follows a symlink planted at that path
    // (predictable, in a dir the plugin itself created) straight through
    // to whatever it points at, and there'd be a window before chmod where
    // the file sits at the default umask. mktemp creates its file at 0600
    // up front (chmod is redundant but explicit), and mv on the same
    // filesystem is a rename(2), which replaces the destination directory
    // entry atomically instead of writing through it — so a symlink at the
    // final path gets replaced, never followed. `head -c` bounds what the
    // writer will ever accept, mirroring the cap on the read side.
    stateWriteProcess.command = [root.bin.bash, "-c",
      "set -e; d=\"$(dirname \"$0\")\"; mkdir -p \"$d\"; chmod 700 \"$d\"; " +
      "tmp=\"$(mktemp \"$d/.state.json.XXXXXX\")\"; chmod 600 \"$tmp\"; " +
      "if head -c 1048576 > \"$tmp\"; then mv -f \"$tmp\" \"$0\"; else rm -f \"$tmp\"; exit 1; fi",
      root.statePath
    ]
    stateWriteProcess.running = true
    stateWriteProcess.write(payload)
    stateWriteProcess.stdinEnabled = false
    // Re-arm for the next write: stdinEnabled=false closes the channel for
    // the running process, and a later `true` only applies to the next one.
    stateWriteProcess.stdinEnabled = true
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

    // `hermes chat --query-file -` reads the message from stdin instead of
    // argv, so the full text (pasted secrets included) never shows up in
    // `ps`/`/proc/<pid>/cmdline` for the life of the request. `-Q --oneshot`
    // reproduces the old top-level `-z`'s contract of "stdout carries only
    // the final response text" (session id / warnings go to stderr).
    var hermesArgs = [root.bin.hermes, "chat", "-Q", "--oneshot", "--query-file", "-",
      "--run-budget", String(root.chatRunBudgetSeconds)]
    if (!root.freshChatPending) hermesArgs.push("-c")
    root.freshChatPending = false
    root.writeState()

    root.busy = true
    root._stdout = ""
    root._stderr = ""
    root._killReason = ""

    // Run the real command in its own process group (`set -m` job control
    // makes the backgrounded job's pgid its own pid) so a TERM sent to that
    // group reaches every descendant Hermes' tool loop spawned, not just the
    // immediate child. The trap self-escalates to KILL after a grace period,
    // entirely inside this spawned shell — that cleanup runs to completion
    // even if this plugin/panel is gone by the time it fires.
    //
    // The job's stdout and stderr each go through a `limit` process
    // substitution rather than straight to Quickshell: `head -c N` forwards
    // at most N bytes, and if even one more byte follows, the limiter sends
    // USR1 (stdout) or USR2 (stderr) back to this wrapper, which kills the
    // job's whole group and exits with a distinct code. So the caps are
    // enforced where the bytes are produced — the shell only ever receives
    // a bounded buffer, and never has to react after the fact. The
    // wrapper's own argv carries only these numbers and the hermes flags;
    // the message itself is written to stdin below.
    var script = "set -m; maxout=$1; maxerr=$2; grace=$3; shift 3; pid=''; excess=0; " +
      "limit() { head -c \"$1\"; if [ \"$(head -c 1 | wc -c)\" -gt 0 ]; then kill -\"$2\" \"$$\" 2>/dev/null; fi; }; " +
      "stop() { if [ -n \"$pid\" ]; then kill -TERM -- \"-$pid\" 2>/dev/null; sleep \"$grace\"; kill -KILL -- \"-$pid\" 2>/dev/null; fi; }; " +
      "trap 'stop' TERM; " +
      "trap 'excess=" + root.excessStdoutExit + "; stop' USR1; " +
      "trap 'excess=" + root.excessStderrExit + "; stop' USR2; " +
      "exec {out}> >(limit \"$maxout\" USR1); outpid=$!; " +
      "exec {err}> >(limit \"$maxerr\" USR2 >&2); errpid=$!; " +
      "\"$@\" >&\"$out\" 2>&\"$err\" & pid=$!; " +
      "exec {out}>&- {err}>&-; " +
      "wait \"$pid\"; rc=$?; wait \"$outpid\" \"$errpid\" 2>/dev/null; " +
      "if [ \"$excess\" -ne 0 ]; then exit \"$excess\"; fi; exit \"$rc\""
    chatProcess.command = [root.bin.bash, "-c", script, "--",
      String(root.maxStdoutBytes), String(root.maxStderrBytes), String(root.killGraceSeconds)
    ].concat(hermesArgs)
    chatProcess.running = true
    // Written to the child's stdin, never to argv — see the comment above.
    chatProcess.write(text)
    chatProcess.stdinEnabled = false
    // Re-arm for the next send: stdinEnabled=false closes the channel for
    // the running process, and a later `true` only applies to the next one.
    chatProcess.stdinEnabled = true
    chatDeadlineTimer.restart()
  }

  // Sends TERM to the whole job (see the wrapper script in sendMessage()),
  // which self-escalates to KILL if the group hasn't exited within
  // killGraceSeconds. Used by the Stop button, the hard deadline, and
  // panel/plugin teardown.
  function killChatProcess(reason) {
    if (!chatProcess.running) return
    root._killReason = reason
    chatProcess.signal(15) // SIGTERM
    killFallbackTimer.restart()
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

  // Swaps the About page in or out. Focus moves to escCatcher while it shows
  // (so Esc steps back) and returns to the composer afterwards.
  function setAbout(on) {
    root.showAbout = !!on
    Qt.callLater(function() {
      if (root.showAbout) escCatcher.forceActiveFocus()
      else if (root.opened) (root.hermesAvailable ? draftField : escCatcher).forceActiveFocus()
    })
  }

  // Re-read on every open (not just once at startup) so switching monitors
  // — a genuinely different component instance — picks up whatever the
  // last-used monitor's instance wrote.
  onOpenedChanged: {
    if (opened) { root.errorText = ""; root.readState() }
    else root.showAbout = false
  }

  Component.onCompleted: root.resolveBinaries()
  // Panel/plugin teardown: fire TERM at whatever chat job is still running.
  // The wrapper's own trap escalates to KILL on its own timeline (see
  // sendMessage()), so that cleanup still runs to completion even though
  // this component and its Timers are being destroyed right now.
  Component.onDestruction: if (chatProcess.running) chatProcess.signal(15)

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
    stdinEnabled: true
    onExited: root.flushState()
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
    stdinEnabled: true
    // Both collectors only ever see a bounded stream: the wrapper script in
    // sendMessage() caps each one producer-side (maxStdoutBytes /
    // maxStderrBytes) and kills the job on the first excess byte, so there's
    // nothing to police here — waitForEnd just hands over the bounded text.
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
      chatDeadlineTimer.stop()
      killFallbackTimer.stop()
      if (root._killReason) {
        root.errorText = root._killReason
        root._killReason = ""
        return
      }
      if (exitCode === root.excessStdoutExit) {
        root.errorText = "Hermes produced too much output and was stopped."
        return
      }
      if (exitCode === root.excessStderrExit) {
        root.errorText = "Hermes produced too much error output and was stopped."
        return
      }
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
        // Unlike the old top-level `-z` (which redirected the whole run's
        // stdout to devnull and only printed the final response at the
        // very end), some `hermes chat` failure paths — e.g. an exhausted
        // HTTP retry loop — print their message to stdout rather than
        // stderr even under -Q. Check both so a real error doesn't get
        // swallowed in favor of a bare "session_id: ..." line on stderr.
        var errText = [root._stderr.trim(), root._stdout.trim()]
          .filter(function(s) { return s.length > 0 }).join("\n")
        root.errorText = errText || ("hermes exited with code " + exitCode)
      }
    }
  }

  // Hard deadline for a chat job: if it's still running when this fires,
  // it's killed regardless of --run-budget.
  Timer {
    id: chatDeadlineTimer
    interval: root.chatHardTimeoutSeconds * 1000
    repeat: false
    onTriggered: root.killChatProcess(
      "Hermes didn't respond within " + root.chatHardTimeoutSeconds + "s and was stopped.")
  }

  // Last-resort hard stop if the process-group wrapper's own TERM/KILL
  // escalation somehow didn't bring the job down in time.
  Timer {
    id: killFallbackTimer
    interval: (root.killGraceSeconds + 5) * 1000
    repeat: false
    onTriggered: if (chatProcess.running) chatProcess.running = false
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
    contentHeight: panel.fittedContentHeight(root.showAbout ? aboutView.implicitHeight :
      topSection.implicitHeight + Style.space(12) + transcriptColumn.implicitHeight + Style.space(12) + bottomSection.implicitHeight,
      Style.space(520)
    )

    Item {
      id: escCatcher
      anchors.fill: parent
      focus: true
      // Esc steps back out of About before it closes the dropdown.
      Keys.onEscapePressed: root.showAbout ? root.setAbout(false) : root.close()

      Flickable {
        anchors.fill: parent
        visible: root.showAbout
        contentWidth: width
        contentHeight: aboutView.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        AboutView {
          id: aboutView
          width: parent.width
          visible: root.showAbout
          foreground: root.foreground
          fontFamily: root.fontFamily
          onBackRequested: root.setAbout(false)
        }
      }

      Column {
        id: topSection
        visible: !root.showAbout
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
          trailingControl: Component {
            PanelActionButton {
              objectName: "aboutButton"
              iconText: "󰋽"
              tooltipText: "About Hermes Chat"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.setAbout(true)
            }
          }
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
        visible: !root.showAbout
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
        visible: !root.showAbout
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
              onClicked: root.killChatProcess("Stopped.")
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
