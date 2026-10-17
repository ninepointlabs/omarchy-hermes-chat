// Node test runner (`node --test tests/`) for the About page's facts. They come
// from the repo's own files (manifest.json, LICENSE, git history), and the
// privacy statement is checked against what Panel.qml actually does. Nothing
// here runs hermes or touches the network.
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { execFileSync } = require("node:child_process")
const About = require("../About.js")

const ROOT = path.join(__dirname, "..")
const read = (name) => fs.readFileSync(path.join(ROOT, name), "utf8")
const sources = () => fs.readdirSync(ROOT).filter((f) => /\.(qml|js|sh)$/.test(f))

test("version comes from manifest.json", () => {
  const manifest = read("manifest.json")
  assert.equal(About.manifestVersion(manifest), JSON.parse(manifest).version)
  assert.equal(About.manifestVersion("not json"), "")
  assert.equal(About.manifestVersion('{"version":"1.0 <b>"}'), "")
  assert.equal(About.NAME, JSON.parse(manifest).name)
})

test("license summary and text come from LICENSE", () => {
  const text = read("LICENSE")
  assert.equal(About.licenseSummary(text), "MIT License, © 2026 Nine Point Labs")
  const body = About.licenseBody(text)
  assert.ok(body.startsWith("MIT License\n\nCopyright (c) 2026 Nine Point Labs\n\nPermission is hereby granted"))
  assert.ok(body.includes('THE SOFTWARE IS PROVIDED "AS IS"'))
  assert.ok(!body.includes("a copy\nof"), "one line per paragraph")
})

test("facts: Nine Point Labs, created date, support address", () => {
  assert.equal(About.ORGANIZATION, "Nine Point Labs")
  assert.equal(About.SUPPORT_EMAIL, "help@ninepointlabs.com")
  const first = execFileSync("git", ["log", "--reverse", "--format=%ad", "--date=format:%B %Y"],
    { cwd: ROOT, encoding: "utf8" }).split("\n")[0]
  assert.equal(About.CREATED, first)
})

test("no old spelling of Nine Point Labs is left", () => {
  for (const f of sources().concat(["LICENSE", "README.md", "manifest.json"]))
    assert.ok(!/ninepoint labs/i.test(read(f)), f)
})

test("install.sh deploys the About files", () => {
  const install = read("install.sh")
  assert.match(install, /"\$DIR"\/\*\.js/)
  assert.match(install, /"\$DIR"\/LICENSE/)
})

test("privacy statement matches how Panel.qml reaches Hermes", () => {
  const panel = read("Panel.qml")
  // The message goes to the local hermes CLI over stdin, not argv or a URL.
  assert.match(panel, /"chat", "-Q", "--oneshot", "--query-file", "-"/)
  assert.match(panel, /chatProcess\.write\(text\)/)
  assert.match(About.PRIVACY, /only to your local Hermes agent/)
  assert.match(About.PRIVACY, /standard input/)
  assert.match(About.PRIVACY, /no telemetry/)
  // Where the transcript is stored, and how much of it.
  assert.ok(panel.includes('"/.local/state/omarchy/hermes-chat/state.json"'))
  assert.ok(About.PRIVACY.includes("~/.local/state/omarchy/hermes-chat/state.json"))
  assert.match(panel, /\.slice\(-20\)/)
  assert.match(About.PRIVACY, /last 20 messages/)
})

test("every network host in the plugin is named in the privacy statement", () => {
  const hosts = new Set()
  for (const f of sources()) {
    if (f === "About.js") continue // the privacy text itself
    for (const m of read(f).matchAll(/\b(?:https?|wss?|ftp):\/\/([^/"'\s$:)]+)/g)) hosts.add(m[1])
  }
  for (const host of hosts) assert.ok(About.PRIVACY.includes(host), `${host} is not named in About.PRIVACY`)
  // Today there are none: the privacy text says the plugin makes no network
  // connections of its own. Adding any network client means rewriting it.
  if (hosts.size === 0) assert.match(About.PRIVACY, /makes no network connections of its own/)
  for (const f of sources()) {
    if (f === "About.js") continue
    const hit = /\b(XMLHttpRequest|WebSocket|curl|wget|socat|ncat)\b|\/dev\/tcp\//.exec(read(f))
    assert.equal(hit, null, `${f} uses ${hit && hit[0]}; update About.PRIVACY and this test`)
  }
})

test("Built with names the toolkit versions", () => {
  assert.equal(About.probedVersion((major, minor) => major === 6 && minor <= 11, 6), "6.11")
  assert.equal(About.probedVersion((major, minor) => major === 0 && minor <= 3, 0), "0.3")
  assert.equal(About.probedVersion(() => false, 6), "")
  assert.equal(About.builtWith("0.3", "6.11"), "Quickshell 0.3, Qt 6.11")
  assert.equal(About.builtWith("", ""), "Quickshell and Qt")
})

test("mailto prefills subject and version details", () => {
  const details = About.details("0.1.0", "0.3", "6.11", "Hyprland, wayland")
  assert.equal(details, "Hermes Chat 0.1.0\nQuickshell 0.3, Qt 6.11\nHyprland, wayland")
  const url = About.mailto("0.1.0", details)
  assert.ok(url.startsWith("mailto:help@ninepointlabs.com?subject=Hermes%20Chat%200.1.0&body="))
  assert.equal(decodeURIComponent(url.split("&body=")[1]), "\n\n--\n" + details)
})
