.pragma library

// Every command Hermes Chat runs is built here, as an argument vector whose
// first element is a fixed absolute path. Nothing is resolved through PATH,
// nothing goes through a shell, and every Process that runs one of these sets
// clearEnvironment and receives only environment() below.
//
//   /usr/bin/python3 -I -S -B  fixed interpreter; -I ignores PYTHON* variables
//                              and the user site directory, -S skips site.
//   bin/bounded-run            race-free supervisor: output caps, deadline,
//                              process-group teardown on stop.
//   bin/hermes-verify          verifies the pacman-installed hermes-agent and
//                              its interpreter before every use, then execs it.
//   bin/hermes-state           descriptor-relative, no-follow state file I/O.

var trustedPython = "/usr/bin/python3"
var pythonFlags = ["-I", "-S", "-B"]
var tools = {
  pgrep: "/usr/bin/pgrep",
  hyprctl: "/usr/bin/hyprctl",
  notifySend: "/usr/bin/notify-send"
}

var exitCodes = {
  timeout: 124,
  spawnFailed: 125,
  notExecutable: 126,
  notFound: 127,
  stdoutCap: 201,
  stderrCap: 202,
  hermesMissing: 210,
  hermesMismatch: 211,
  hermesUnapproved: 212,
  verifyUsage: 213,
  stateRefused: 3,
  stateInvalid: 4
}

var chatStdoutBytes = 262144
var chatStderrBytes = 65536
var killGraceSeconds = 3
var stateBytes = 1048576
var maxApprovals = 8

var approvalPattern = /^[0-9][A-Za-z0-9._+~:-]{0,63}@[0-9a-f]{64}$/
var pathPattern = /^\/(?:[A-Za-z0-9._+@-]+\/)*[A-Za-z0-9._+@-]+$/

var baseEnvironmentNames = ["LANG", "LC_ALL", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
  "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"]
var sessionEnvironmentNames = ["WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
  "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "HYPRLAND_INSTANCE_SIGNATURE"]
var pathValuedNames = ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
  "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"]

function validPath(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (!pathPattern.test(text)) return ""
  var parts = text.split("/")
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "." || parts[i] === "..") return ""
  }
  return text
}

function pluginDirFromUrl(url) {
  var text = String(url || "")
  if (text.indexOf("file://") !== 0) return ""
  var path
  try { path = decodeURIComponent(text.slice(7)) } catch (e) { return "" }
  return validPath(path.replace(/\/+$/, ""))
}

function helperPath(pluginDir, name) {
  var dir = validPath(pluginDir)
  return dir === "" ? "" : dir + "/bin/" + name
}

function pythonHelper(pluginDir, name, args) {
  var helper = helperPath(pluginDir, name)
  if (helper === "") return []
  return [trustedPython].concat(pythonFlags, [helper], args || [])
}

// `argv[0]` must already be a clean absolute path. Anything else yields [],
// and a Process given an empty command starts nothing.
function boundedRun(pluginDir, limits, argv) {
  var runner = helperPath(pluginDir, "bounded-run")
  var source = Array.isArray(argv) ? argv : []
  if (runner === "" || source.length === 0 || validPath(source[0]) === "") return []
  return [trustedPython].concat(pythonFlags, [runner,
    "--stdout-cap", String(limits.stdout), "--stderr-cap", String(limits.stderr),
    "--deadline", String(limits.deadline), "--grace", String(limits.grace), "--"], source)
}

function sanitizeApprovals(list) {
  var source = Array.isArray(list) ? list : []
  var result = []
  for (var i = 0; i < source.length && result.length < maxApprovals; i++) {
    var text = String(source[i])
    if (approvalPattern.test(text) && result.indexOf(text) < 0) result.push(text)
  }
  return result
}

function approvalArgs(list) {
  var args = []
  var approvals = sanitizeApprovals(list)
  for (var i = 0; i < approvals.length; i++) args.push("--approve", approvals[i])
  return args
}

function stateReadCommand(pluginDir) {
  return boundedRun(pluginDir, { stdout: stateBytes, stderr: 4096, deadline: 15, grace: 1 },
    pythonHelper(pluginDir, "hermes-state", ["read"]))
}

function stateWriteCommand(pluginDir) {
  return boundedRun(pluginDir, { stdout: 4096, stderr: 4096, deadline: 15, grace: 1 },
    pythonHelper(pluginDir, "hermes-state", ["write"]))
}

function verifyCommand(pluginDir, approvals) {
  return boundedRun(pluginDir, { stdout: 16384, stderr: 16384, deadline: 120, grace: 2 },
    pythonHelper(pluginDir, "hermes-verify", ["check"].concat(approvalArgs(approvals))))
}

// The message itself is written to stdin (`--query-file -`), never argv.
function chatCommand(pluginDir, approvals, runBudgetSeconds, hardTimeoutSeconds, continueLatest) {
  var hermesArgs = ["chat", "-Q", "--oneshot", "--query-file", "-",
    "--run-budget", String(runBudgetSeconds)]
  if (continueLatest) hermesArgs.push("-c")
  // The panel's own deadline timer stops the job first and says why; the
  // supervisor's deadline is the backstop if the shell itself stalls.
  return boundedRun(pluginDir,
    { stdout: chatStdoutBytes, stderr: chatStderrBytes, deadline: hardTimeoutSeconds + 10, grace: killGraceSeconds },
    pythonHelper(pluginDir, "hermes-verify", ["exec"].concat(approvalArgs(approvals), ["--"], hermesArgs)))
}

// Launched detached: the desktop app is meant to outlive the panel.
function desktopCommand(pluginDir, approvals) {
  return pythonHelper(pluginDir, "hermes-verify",
    ["exec", "--gui"].concat(approvalArgs(approvals), ["--", "desktop", "--skip-build"]))
}

function desktopRunningCommand(pluginDir) {
  return boundedRun(pluginDir, { stdout: 4096, stderr: 4096, deadline: 5, grace: 1 },
    [tools.pgrep, "-f", "apps/desktop/release/linux-unpacked/Hermes$"])
}

function focusDesktopCommand(pluginDir) {
  return boundedRun(pluginDir, { stdout: 4096, stderr: 4096, deadline: 5, grace: 1 },
    [tools.hyprctl, "dispatch", "focuswindow", "class:^(Hermes)$"])
}

// No reply text on the command line: the notification only says a reply
// arrived, so model output never lands in /proc/<pid>/cmdline.
function notifyCommand(pluginDir) {
  return boundedRun(pluginDir, { stdout: 4096, stderr: 4096, deadline: 10, grace: 1 },
    [tools.notifySend, "-a", "Hermes", "Hermes replied", "Open Hermes Chat in the bar to read it."])
}

// A fixed PATH plus an allow-list of session variables, each refused unless it
// is a bounded single-line value (and an absolute path, for the XDG dirs).
// `lookup` is Quickshell.env.
function environment(lookup, includeSession) {
  var result = { PATH: "/usr/bin:/bin" }
  var names = includeSession ? baseEnvironmentNames.concat(sessionEnvironmentNames) : baseEnvironmentNames
  for (var i = 0; i < names.length; i++) {
    var value = lookup(names[i])
    if (value === undefined || value === null) continue
    var text = String(value)
    if (text === "" || text.length > 4096 || /[\x00-\x1f\x7f]/.test(text)) continue
    if (pathValuedNames.indexOf(names[i]) >= 0 && validPath(text) === "") continue
    result[names[i]] = text
  }
  return result
}

function boundedText(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
    .replace(/[\x00-\x08\x0b-\x1f\x7f​-‏‪-‮⁦-⁩]/g, "")
  return text.length > limit ? text.slice(0, limit) + "…" : text
}

// hermes-verify check prints a single JSON object; anything else is treated
// as an error rather than trusted.
function parseVerifyOutput(text) {
  var parsed
  try { parsed = JSON.parse(String(text || "").trim()) } catch (e) { return { status: "error", reason: "Could not read the verifier's result" } }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || typeof parsed.status !== "string")
    return { status: "error", reason: "Could not read the verifier's result" }
  return {
    status: boundedText(parsed.status, 32),
    reason: boundedText(parsed.reason || "", 400),
    path: boundedText(parsed.path || "", 240),
    version: boundedText(parsed.version || "", 64),
    approval: approvalPattern.test(String(parsed.approval || "")) ? String(parsed.approval) : "",
    tested: Array.isArray(parsed.tested) ? parsed.tested.map(function(v) { return boundedText(v, 64) }).join(", ") : ""
  }
}

function sanitizeTranscript(list) {
  var source = Array.isArray(list) ? list : []
  var result = []
  for (var i = Math.max(0, source.length - 20); i < source.length; i++) {
    var entry = source[i]
    if (!entry || typeof entry !== "object") continue
    if (entry.role !== "user" && entry.role !== "assistant") continue
    result.push({ role: entry.role, text: String(entry.text === undefined ? "" : entry.text).slice(0, 8000) })
  }
  return result
}
