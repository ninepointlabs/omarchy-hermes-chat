// Facts and text for the About page (AboutView.qml), kept out of QML so node
// can check them (see tests/about.test.cjs).
//
// The version comes from manifest.json and the license from LICENSE at run
// time, so neither is copied here and neither can drift from the real file.

var NAME = "Hermes Chat"
var TAGLINE = "Send a quick message to your local Hermes agent from the bar, without opening the desktop app."
var ORGANIZATION = "Nine Point Labs"
var CREATED = "August 2026" // first commit: 2026-08-30
var SUPPORT_EMAIL = "help@ninepointlabs.com"

// Must stay true to what Panel.qml does. It makes no network connection of
// its own: a message is written to the stdin of `hermes chat --oneshot
// --query-file -`, run on this computer. Files: state.json (below). Other
// commands: hermes --version, notify-send, pgrep/hyprctl/hermes desktop.
var PRIVACY = "No account, no sign-in and no telemetry, and the plugin makes no network connections of its own. "
  + "Your message goes only to your local Hermes agent: the plugin runs the hermes command on this computer "
  + "and hands it the message over standard input. What Hermes then does with it, such as sending it to the "
  + "AI model provider it is configured with, or keeping it in its own conversation history, is Hermes's own "
  + "behaviour under its settings. The plugin reads no API keys or tokens. Your last 20 messages and replies "
  + "and the notify setting are kept in ~/.local/state/omarchy/hermes-chat/state.json, readable only by you; "
  + "New chat clears the saved messages. With Notify me on answers on, the start of a reply is shown in a desktop notification."

// "0.1.0" from manifest.json's text, or "" when it can't be read.
function manifestVersion(text) {
  try {
    var v = JSON.parse(String(text || "")).version
    return typeof v === "string" && /^[0-9A-Za-z.+-]{1,32}$/.test(v) ? v : ""
  } catch (e) {
    return ""
  }
}

// "MIT License, © 2026 Nine Point Labs" from LICENSE's text: its first line
// plus its copyright line, as written there.
function licenseSummary(text) {
  var lines = String(text || "").split("\n")
  var name = ""
  var holder = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (name === "") name = line
    var m = /^Copyright\s+(?:\(c\)|©)\s*(.+)$/i.exec(line)
    if (m) { holder = "© " + m[1]; break }
  }
  return holder ? name + ", " + holder : name
}

// LICENSE with one line per paragraph, so it wraps to the panel's width.
function licenseBody(text) {
  var paras = String(text || "").replace(/\r/g, "").split(/\n\s*\n/)
  var out = []
  for (var i = 0; i < paras.length; i++) {
    var p = paras[i].split(/\s+/).join(" ").trim()
    if (p !== "") out.push(p)
  }
  return out.join("\n\n")
}

// Highest minor version `has(major, minor)` accepts, as "major.minor"
// (Quickshell.hasVersion / hasQtVersion only answer yes or no), or "".
function probedVersion(has, major) {
  if (typeof has !== "function" || !has(major, 0)) return ""
  var minor = 0
  while (minor < 99 && has(major, minor + 1)) minor++
  return major + "." + minor
}

function builtWith(quickshell, qt) {
  var out = []
  if (quickshell) out.push("Quickshell " + quickshell)
  if (qt) out.push("Qt " + qt)
  return out.length ? out.join(", ") : "Quickshell and Qt"
}

// Version details to paste into a support email.
function details(version, quickshell, qt, desktop) {
  return NAME + " " + (version || "unknown version") + "\n"
    + builtWith(quickshell, qt) + "\n"
    + (desktop || "unknown desktop")
}

function mailto(version, detailText) {
  return "mailto:" + SUPPORT_EMAIL
    + "?subject=" + encodeURIComponent(NAME + " " + (version || ""))
    + "&body=" + encodeURIComponent("\n\n--\n" + detailText)
}

if (typeof module !== "undefined") {
  module.exports = {
    NAME: NAME, TAGLINE: TAGLINE, ORGANIZATION: ORGANIZATION, CREATED: CREATED,
    SUPPORT_EMAIL: SUPPORT_EMAIL, PRIVACY: PRIVACY,
    manifestVersion: manifestVersion, licenseSummary: licenseSummary, licenseBody: licenseBody,
    probedVersion: probedVersion, builtWith: builtWith, details: details, mailto: mailto
  }
}
