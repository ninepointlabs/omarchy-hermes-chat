import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Hermes.js" as Hermes

// Bar icon + dropdown for talking to the local Hermes agent without opening
// the Hermes desktop app. Each send runs `hermes chat -Q --oneshot
// --query-file -` (one-shot mode, message piped over stdin rather than argv)
// as its own child process tree — there is no daemon here, matching the CLI's
// own model where a one-shot turn doesn't require the persistent gateway.
// `-c`/`--continue` is added on every send except the one right after "New
// chat", so quick chat naturally continues whatever Hermes conversation is
// currently most recent.
//
// Trust boundary (see README "Security model" and Hermes.js):
//   - Hermes is never looked up on PATH. bin/hermes-verify accepts only the
//     pacman-installed hermes-agent, checks its whole runtime closure against
//     pacman's record immediately before every use, and then execs the venv
//     interpreter itself. Drift, extra files, or an unapproved version fail
//     closed.
//   - No shell anywhere: every command is an argv vector starting with a fixed
//     absolute path, run under bin/bounded-run (output caps, deadline,
//     race-free process-group teardown), with a cleared environment.
//   - The state file is only touched by bin/hermes-state, through held
//     directory descriptors, over stdin/stdout.
Panel {
  id: root
  moduleName: "tim.hermes-chat"
  ipcTarget: "tim.hermes-chat"
  manageIpc: false

  readonly property string pluginDir: Hermes.pluginDirFromUrl(Qt.resolvedUrl("."))
  // Environments for child processes, in place of the shell's own: a fixed
  // PATH plus an allow-list of single-line session variables (Hermes.js).
  readonly property var processEnvironment: Hermes.environment(function(name) { return Quickshell.env(name) }, false)
  readonly property var sessionEnvironment: Hermes.environment(function(name) { return Quickshell.env(name) }, true)

  // "checking" | "ok" | "missing" | "mismatch" | "unapproved" | "error"
  property string verifyStatus: "checking"
  property var verifyInfo: ({})
  readonly property bool hermesAvailable: verifyStatus === "ok"
  property bool _verifyAgain: false
  property bool _initialVerifyDone: false
  property string _verifyStdout: ""

  property bool busy: false
  property bool freshChatPending: false
  property string draft: ""
  property string errorText: ""
  property bool notifyOnAnswers: false
  property var transcript: [] // [{ role: "user"|"assistant", text }]
  // hermes-agent builds the user explicitly trusted, as "VERSION@SHA256(mtree)".
  property var approvedHermes: []
  property string _stdout: ""
  property string _stderr: ""
  property string _stateStdout: ""
  property string _stateStderr: ""
  property string _writeStderr: ""
  // Nothing is written until the state file has been read once, so a write
  // can never replace saved approvals/preferences with defaults.
  property bool _stateLoaded: false
  // Latest state payload waiting for stateWriteProcess to be free (see
  // flushState()); only the newest matters, so later writes replace it.
  property string _pendingState: ""
  readonly property int maxReplyChars: 4000
  // Byte caps on the chat job's stdout/stderr are enforced producer-side by
  // bin/bounded-run (Hermes.chatStdoutBytes / chatStderrBytes): at most that
  // many bytes ever reach Quickshell, and the first byte past a cap tears the
  // whole job down with exit 201 / 202.
  // Soft deadline passed to `hermes --run-budget`: the agent gets a wrap-up
  // nudge at 80% elapsed and tries to land a response before this. The hard
  // deadline below is the actual enforcement.
  readonly property int chatRunBudgetSeconds: 240
  // Hard local deadline: if the job hasn't exited by here, it's stopped.
  readonly property int chatHardTimeoutSeconds: 300
  // Set right before killChatProcess() signals the job, so onExited can show
  // *why* it ended instead of a bare "hermes exited with code N".
  property string _killReason: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: !hermesAvailable && verifyStatus !== "checking" ? urgent : foreground

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function verifyHermes() {
    if (verifyProcess.running) {
      root._verifyAgain = true
      return
    }
    var command = Hermes.verifyCommand(root.pluginDir, root.approvedHermes)
    if (command.length === 0) {
      root.verifyStatus = "error"
      root.verifyInfo = { reason: "The plugin's install path isn't usable." }
      return
    }
    root.verifyStatus = "checking"
    root._verifyStdout = ""
    verifyProcess.command = command
    verifyProcess.running = true
  }

  function applyVerifyResult(exitCode) {
    var result = Hermes.parseVerifyOutput(root._verifyStdout)
    var expected = {}
    expected[0] = "ok"
    expected[Hermes.exitCodes.hermesMissing] = "missing"
    expected[Hermes.exitCodes.hermesMismatch] = "mismatch"
    expected[Hermes.exitCodes.hermesUnapproved] = "unapproved"
    if (expected[exitCode] !== undefined && result.status === expected[exitCode]) {
      root.verifyInfo = result
      root.verifyStatus = result.status
    } else {
      root.verifyInfo = { reason: "the verifier exited with code " + exitCode + "." }
      root.verifyStatus = "error"
    }
  }

  function approveInstalledHermes() {
    var approval = root.verifyInfo.approval || ""
    if (root.verifyStatus !== "unapproved" || !approval) return
    root.approvedHermes = Hermes.sanitizeApprovals([approval].concat(root.approvedHermes))
    root.writeState()
    root.verifyHermes()
  }

  function unavailableMessage() {
    var info = root.verifyInfo || {}
    if (root.verifyStatus === "missing")
      return "Hermes Chat only runs the pacman-installed hermes-agent package, and it isn't installed. Install hermes-agent, then Re-check."
    if (root.verifyStatus === "mismatch")
      return "Your hermes-agent install doesn't match its pacman package record, so Hermes Chat won't run it: "
        + (info.reason || "unknown difference") + (info.path ? " (" + info.path + ")" : "")
        + ". Restore the package's files and root ownership (`pacman -Qkk hermes-agent` lists what differs) and remove anything added under /opt/hermes-agent, then Re-check."
    if (root.verifyStatus === "unapproved")
      return "hermes-agent " + (info.version || "?") + " is installed and matches its package record, but this Hermes Chat release was tested with "
        + (info.tested || "a different version") + ". Trusting it lets that exact package build handle your messages."
    return "Couldn't verify the Hermes install: " + (info.reason || "unknown error")
  }

  // Reads state.json through bin/hermes-state (which also carries over the
  // notify preference from the plugin's older prefs file). The helper caps
  // what it reads at 1 MiB and refuses anything that isn't the user's own
  // private regular file.
  function readState() {
    if (stateReadProcess.running) return
    var command = Hermes.stateReadCommand(root.pluginDir)
    if (command.length === 0) {
      root.errorText = "Couldn't load chat state: the plugin's install path isn't usable."
      return
    }
    root._stateStdout = ""
    root._stateStderr = ""
    stateReadProcess.command = command
    stateReadProcess.running = true
  }

  function writeState() {
    root._pendingState = JSON.stringify({
      transcript: root.transcript,
      freshChatPending: root.freshChatPending,
      notifyOnAnswers: root.notifyOnAnswers,
      approvedHermes: root.approvedHermes
    })
    root.flushState()
  }

  // Starts the writer for whatever payload is pending, unless one is already
  // in flight — in which case stateWriteProcess.onExited calls back here.
  // Quickshell ignores `command` changes while a Process is running and
  // write() goes to the *current* process, so without this guard two quick
  // writes would push the second payload into the first writer's stdin.
  function flushState() {
    if (!root._stateLoaded || stateWriteProcess.running || !root._pendingState) return
    var command = Hermes.stateWriteCommand(root.pluginDir)
    if (command.length === 0) return
    var payload = root._pendingState
    root._pendingState = ""
    root._writeStderr = ""
    // The payload — the whole conversation transcript — goes to the writer
    // over stdin, never argv, so prompts and replies don't sit in
    // /proc/<pid>/cmdline. The writer's argv is fixed.
    stateWriteProcess.command = command
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
    if (typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}
    root.transcript = Hermes.sanitizeTranscript(parsed.transcript)
    root.freshChatPending = !!parsed.freshChatPending
    root.notifyOnAnswers = !!parsed.notifyOnAnswers
    root.approvedHermes = Hermes.sanitizeApprovals(parsed.approvedHermes)
    root._stateLoaded = true
    root.scrollToLatest()
    root.flushState()
  }

  function appendTranscript(entry) {
    // Cap history so the state file (re-read on every open) can't grow
    // without bound over weeks of quick-chat use.
    root.transcript = root.transcript.concat([entry]).slice(-20)
    root.scrollToLatest()
  }

  // Jumps the transcript scroll area to the newest message. Qt.callLater
  // defers this past the Repeater/Column relayout that follows a
  // transcript change, so contentHeight is already current when this runs.
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
    if (!text || root.busy || !root.hermesAvailable) return

    // bin/hermes-verify re-verifies the install and then execs Hermes with
    // `chat -Q --oneshot --query-file -`: the message is written to stdin
    // below, never to argv.
    var command = Hermes.chatCommand(root.pluginDir, root.approvedHermes,
      root.chatRunBudgetSeconds, root.chatHardTimeoutSeconds, !root.freshChatPending)
    if (command.length === 0) {
      root.errorText = "Couldn't start Hermes: the plugin's install path isn't usable."
      return
    }

    root.errorText = ""
    root.appendTranscript({ role: "user", text: text })
    root.draft = ""
    root.freshChatPending = false
    root.writeState()

    root.busy = true
    root._stdout = ""
    root._stderr = ""
    root._killReason = ""

    chatProcess.command = command
    chatProcess.running = true
    chatProcess.write(text)
    chatProcess.stdinEnabled = false
    // Re-arm for the next send: stdinEnabled=false closes the channel for
    // the running process, and a later `true` only applies to the next one.
    chatProcess.stdinEnabled = true
    chatDeadlineTimer.restart()
  }

  // TERM to the supervisor, which tears down the whole job — every
  // descendant, TERM then KILL after its grace window — before it exits.
  // Used by the Stop button, the hard deadline, and panel/plugin teardown.
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

  // Focuses the Hermes window if it's open, otherwise launches the desktop
  // app through the same verified path as chat.
  function showFullApp() {
    haptic()
    if (!root.hermesAvailable) {
      root.errorText = "The desktop app can't be opened from here until the Hermes install verifies."
      return
    }
    var command = Hermes.desktopRunningCommand(root.pluginDir)
    if (command.length === 0 || desktopProbeProcess.running) return
    desktopProbeProcess.command = command
    desktopProbeProcess.running = true
    root.close()
  }

  // No haptics service is wired into this base kit the way the Hermes
  // desktop SDK has one — left as a no-op seam.
  function haptic() {}

  // Re-read on every open (not just once at startup) so switching monitors
  // — a genuinely different component instance — picks up whatever the
  // last-used monitor's instance wrote.
  onOpenedChanged: if (opened) {
    root.errorText = ""
    root.readState()
    if (root._initialVerifyDone && root.verifyStatus !== "ok" && root.verifyStatus !== "checking") root.verifyHermes()
  }

  Component.onCompleted: root.readState()
  // Panel/plugin teardown: TERM the supervisor; it finishes tearing the job
  // down on its own (and also receives TERM if the shell itself dies).
  Component.onDestruction: if (chatProcess.running) chatProcess.signal(15)

  Process {
    id: verifyProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.processEnvironment
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._verifyStdout = text
    }
    onExited: function(exitCode) {
      root.applyVerifyResult(exitCode)
      if (root._verifyAgain) {
        root._verifyAgain = false
        root.verifyHermes()
      }
    }
  }

  Process {
    id: stateReadProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.processEnvironment
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._stateStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._stateStderr = text
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyState(root._stateStdout)
      } else {
        root.errorText = Hermes.boundedText(root._stateStderr.trim(), 400)
          || ("Couldn't load chat state (exit " + exitCode + ").")
      }
      root._stateStdout = ""
      if (!root._initialVerifyDone) {
        root._initialVerifyDone = true
        root.verifyHermes()
      }
    }
  }

  Process {
    id: stateWriteProcess
    running: false
    command: []
    stdinEnabled: true
    clearEnvironment: true
    environment: root.processEnvironment
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._writeStderr = text
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.errorText = Hermes.boundedText(root._writeStderr.trim(), 400)
          || ("Couldn't save chat state (exit " + exitCode + ").")
      }
      root.flushState()
    }
  }

  Process {
    id: desktopProbeProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.processEnvironment
    onExited: function(exitCode) {
      // pgrep: 0 = the desktop app is running, 1 = it isn't. Anything else
      // (including 127 when pgrep isn't installed) leaves the feature inert.
      if (exitCode === 0) {
        focusProcess.command = Hermes.focusDesktopCommand(root.pluginDir)
        focusProcess.running = true
      } else if (exitCode === 1) {
        desktopLaunchProcess.command = Hermes.desktopCommand(root.pluginDir, root.approvedHermes)
        if (desktopLaunchProcess.command.length > 0) desktopLaunchProcess.startDetached()
      }
    }
  }

  Process {
    id: focusProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.sessionEnvironment
  }

  Process {
    id: desktopLaunchProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.sessionEnvironment
  }

  Process {
    id: chatProcess
    running: false
    command: []
    stdinEnabled: true
    clearEnvironment: true
    environment: root.processEnvironment
    // Both collectors only ever see a bounded stream: bin/bounded-run caps
    // each one producer-side and stops the job on the first excess byte.
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
      if (exitCode === Hermes.exitCodes.stdoutCap) {
        root.errorText = "Hermes produced too much output and was stopped."
        return
      }
      if (exitCode === Hermes.exitCodes.stderrCap) {
        root.errorText = "Hermes produced too much error output and was stopped."
        return
      }
      if (exitCode === Hermes.exitCodes.timeout) {
        root.errorText = "Hermes didn't respond within " + root.chatHardTimeoutSeconds + "s and was stopped."
        return
      }
      if (exitCode === Hermes.exitCodes.hermesMissing || exitCode === Hermes.exitCodes.hermesMismatch
          || exitCode === Hermes.exitCodes.hermesUnapproved) {
        // The install changed since the last check: refuse and re-check.
        root.errorText = Hermes.boundedText(root._stderr.trim(), 400) || "Hermes Chat refused to start Hermes."
        root.verifyHermes()
        return
      }
      if (exitCode === 0) {
        var full = root._stdout.trim() || "(empty response)"
        var reply = full.length > root.maxReplyChars
          ? full.slice(0, root.maxReplyChars) + "… [truncated]"
          : full
        root.appendTranscript({ role: "assistant", text: reply })
        root.writeState()
        if (root.notifyOnAnswers && !root.opened && !notifyProcess.running) {
          notifyProcess.command = Hermes.notifyCommand(root.pluginDir)
          notifyProcess.running = true
        }
      } else {
        // Some `hermes chat` failure paths print their message to stdout
        // rather than stderr even under -Q. Check both so a real error
        // doesn't get swallowed in favor of a bare "session_id: ..." line.
        var errText = [root._stderr.trim(), root._stdout.trim()]
          .filter(function(s) { return s.length > 0 }).join("\n")
        root.errorText = errText || ("hermes exited with code " + exitCode)
      }
    }
  }

  // Hard deadline for a chat job: if it's still running when this fires,
  // it's stopped regardless of --run-budget.
  Timer {
    id: chatDeadlineTimer
    interval: root.chatHardTimeoutSeconds * 1000
    repeat: false
    onTriggered: root.killChatProcess(
      "Hermes didn't respond within " + root.chatHardTimeoutSeconds + "s and was stopped.")
  }

  // Last-resort stop if the supervisor somehow hasn't exited in time.
  Timer {
    id: killFallbackTimer
    interval: (Hermes.killGraceSeconds + 5) * 1000
    repeat: false
    onTriggered: if (chatProcess.running) chatProcess.running = false
  }

  Process {
    id: notifyProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.sessionEnvironment
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
    // the chip) can be followed immediately by typing. Falls back to
    // escCatcher when the field isn't showing, e.g. Hermes not verified.
    focusTarget: root.hermesAvailable ? draftField : escCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
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
          meta: root.verifyStatus === "checking" ? "Checking the Hermes install…"
            : !root.hermesAvailable ? "Hermes install not verified"
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

        // --- Hermes missing, altered, or not approved ----------------------
        Column {
          visible: root.verifyStatus !== "ok" && root.verifyStatus !== "checking"
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: root.unavailableMessage()
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: "Re-check"
              foreground: root.foreground
              bordered: true
              onClicked: root.verifyHermes()
            }

            Button {
              visible: root.verifyStatus === "unapproved" && !!root.verifyInfo.approval
              text: "Trust hermes-agent " + (root.verifyInfo.version || "")
              foreground: root.foreground
              bordered: true
              onClicked: root.approveInstalledHermes()
            }
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
                // messages AND the model's replies, so nothing the model
                // echoes can become a live link or image fetch.
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
