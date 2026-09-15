// node --test tests/hermes-js.test.cjs
const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const root = path.join(__dirname, "..")
const source = fs.readFileSync(path.join(root, "Hermes.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const Hermes = vm.createContext({})
vm.runInContext(source, Hermes)

// Values created inside the vm context have that context's Array prototype;
// copy them into this realm before deep comparisons.
const plain = (value) => JSON.parse(JSON.stringify(value))

const pluginDir = "/home/u/.config/omarchy/plugins/hermes-chat"
const approval = "0.22.0-1@" + "a".repeat(64)

function allCommands() {
  return {
    stateRead: Hermes.stateReadCommand(pluginDir),
    stateWrite: Hermes.stateWriteCommand(pluginDir),
    verify: Hermes.verifyCommand(pluginDir, [approval]),
    chat: Hermes.chatCommand(pluginDir, [approval], 240, 300, true),
    desktop: Hermes.desktopCommand(pluginDir, [approval]),
    desktopRunning: Hermes.desktopRunningCommand(pluginDir),
    focus: Hermes.focusDesktopCommand(pluginDir),
    notify: Hermes.notifyCommand(pluginDir),
  }
}

test("every command starts with the fixed isolated interpreter and never a shell", () => {
  for (const [name, command] of Object.entries(allCommands())) {
    assert.ok(command.length > 0, name)
    assert.deepStrictEqual(plain(command.slice(0, 4)), ["/usr/bin/python3", "-I", "-S", "-B"], name)
    command.forEach((arg, index) => {
      assert.ok(!/^(\/usr)?\/bin\/(ba|z|da)?sh$|^(ba|z|da)?sh$/.test(arg), name + " contains a shell: " + arg)
      // The only -c allowed is Hermes' own --continue flag at the very end.
      if (arg === "-c") assert.ok(name === "chat" && index === command.length - 1, name + " has -c")
    })
  }
})

test("bounded commands run an absolute executable through bounded-run", () => {
  const commands = allCommands()
  for (const name of ["stateRead", "stateWrite", "verify", "chat", "desktopRunning", "focus", "notify"]) {
    const command = commands[name]
    assert.strictEqual(command[4], pluginDir + "/bin/bounded-run", name)
    const inner = command.slice(command.indexOf("--") + 1)
    assert.ok(inner[0].startsWith("/"), name + " runs " + inner[0])
  }
  assert.strictEqual(commands.desktop[4], pluginDir + "/bin/hermes-verify")
})

test("chat goes through hermes-verify exec with stdin for the message", () => {
  const chat = Hermes.chatCommand(pluginDir, [approval], 240, 300, true)
  const inner = chat.slice(chat.indexOf("--") + 1)
  assert.deepStrictEqual(plain(inner.slice(0, 5)), ["/usr/bin/python3", "-I", "-S", "-B", pluginDir + "/bin/hermes-verify"])
  assert.ok(inner.includes("exec"))
  assert.deepStrictEqual(plain(inner.slice(inner.lastIndexOf("--") + 1)),
    ["chat", "-Q", "--oneshot", "--query-file", "-", "--run-budget", "240", "-c"])
  assert.ok(!Hermes.chatCommand(pluginDir, [], 240, 300, false).includes("-c"))
  const caps = chat.slice(0, chat.indexOf("--"))
  assert.strictEqual(caps[caps.indexOf("--stdout-cap") + 1], "262144")
  assert.strictEqual(caps[caps.indexOf("--stderr-cap") + 1], "65536")
  assert.ok(!chat.some((arg) => arg === "hermes" || arg === "/usr/bin/hermes"))
})

test("unusable plugin paths yield no command", () => {
  for (const bad of ["", "relative/dir", "/a/../b", "/a/./b", "/a b", "/a\nb", "/a;b"]) {
    assert.strictEqual(Hermes.stateReadCommand(bad).length, 0, JSON.stringify(bad))
    assert.strictEqual(Hermes.chatCommand(bad, [], 1, 1, false).length, 0, JSON.stringify(bad))
  }
  assert.strictEqual(Hermes.boundedRun(pluginDir, { stdout: 1, stderr: 1, deadline: 1, grace: 1 }, ["notify-send"]).length, 0)
  assert.strictEqual(Hermes.pluginDirFromUrl("file:///home/u/plugins/hermes-chat/"), "/home/u/plugins/hermes-chat")
  assert.strictEqual(Hermes.pluginDirFromUrl("qrc:/x"), "")
  assert.strictEqual(Hermes.pluginDirFromUrl("file:///home/u/%2e%2e/x"), "")
})

test("approvals are validated, deduplicated and capped", () => {
  const many = []
  for (let i = 0; i < 20; i++) many.push("1.0." + i + "-1@" + "b".repeat(64))
  const result = Hermes.sanitizeApprovals(["junk", approval, approval, "0.1@short", "--approve"].concat(many))
  assert.strictEqual(result[0], approval)
  assert.strictEqual(result.length, Hermes.maxApprovals)
  assert.deepStrictEqual(plain(Hermes.approvalArgs(["x;rm -rf /"])), [])
})

test("environment is a fixed PATH plus clean allow-listed values", () => {
  const values = {
    PATH: "/home/u/evil:/usr/bin", BASH_ENV: "/tmp/evil", LD_PRELOAD: "/tmp/x.so", PYTHONPATH: "/tmp",
    LANG: "en_US.UTF-8", XDG_RUNTIME_DIR: "/run/user/1000", XDG_DATA_HOME: "relative",
    XDG_CONFIG_HOME: "/home/u/.config\nPATH=/evil", WAYLAND_DISPLAY: "wayland-1",
  }
  const env = Hermes.environment((name) => values[name], false)
  assert.deepStrictEqual(Object.keys(env).sort(), ["LANG", "PATH", "XDG_RUNTIME_DIR"])
  assert.strictEqual(env.PATH, "/usr/bin:/bin")
  const session = Hermes.environment((name) => values[name], true)
  assert.strictEqual(session.WAYLAND_DISPLAY, "wayland-1")
  assert.ok(!("BASH_ENV" in session) && !("LD_PRELOAD" in session))
})

test("verifier output is parsed defensively", () => {
  assert.strictEqual(Hermes.parseVerifyOutput("not json").status, "error")
  assert.strictEqual(Hermes.parseVerifyOutput("[]").status, "error")
  const parsed = Hermes.parseVerifyOutput(JSON.stringify({
    status: "unapproved", reason: "r‮".repeat(500), version: "0.22.0-1", approval, tested: ["0.21.0-1"],
  }))
  assert.strictEqual(parsed.status, "unapproved")
  assert.ok(parsed.reason.length <= 401 && !parsed.reason.includes("‮"))
  assert.strictEqual(parsed.approval, approval)
  assert.strictEqual(Hermes.parseVerifyOutput(JSON.stringify({ status: "ok", approval: "bad" })).approval, "")
})

test("transcript loaded from disk is shape-checked and capped", () => {
  const list = [{ role: "system", text: "x" }, null, { role: "user", text: 5 }]
  for (let i = 0; i < 30; i++) list.push({ role: "assistant", text: "y".repeat(9000) })
  const result = Hermes.sanitizeTranscript(list)
  assert.strictEqual(result.length, 20)
  assert.ok(result.every((e) => e.role === "assistant" && e.text.length === 8000))
})

test("Panel.qml has no shell, no bare tool names, and clears every Process environment", () => {
  const qml = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
  const code = qml.split("\n").filter((line) => !line.trim().startsWith("//")).join("\n")
  assert.ok(!/"(ba)?sh"|"-c"|command -v|bin\.bash|"hermes"/.test(code))
  const processes = (code.match(/^\s*Process \{/gm) || []).length
  const cleared = (code.match(/clearEnvironment: true/g) || []).length
  assert.ok(processes > 0)
  assert.strictEqual(cleared, processes)
  assert.ok(!/\.command = \[/.test(code), "commands must come from Hermes.js")
})
