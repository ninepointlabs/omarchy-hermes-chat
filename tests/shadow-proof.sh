#!/usr/bin/bash
# Proof that nothing Hermes Chat runs is resolved from PATH or influenced by
# shell/loader/Python injection variables, even if the environment were NOT
# cleared: runs the exact argv vectors Hermes.js builds with a hostile PATH,
# BASH_ENV, ENV, PYTHONPATH, PYTHONSTARTUP and LD_PRELOAD, and checks that no
# planted executable or hook ran.
#
# The state read runs against your real state file (read-only; output is
# discarded). The chat command stops at hermes-verify unless the local
# hermes-agent install verifies, in which case Hermes answers one tiny prompt.
set -u
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
evil="$work/evil"
markers="$work/markers"
mkdir -p "$evil" "$markers"

for name in bash sh python3 python hermes head wc kill mkdir chmod mktemp mv cat pgrep hyprctl notify-send setsid env; do
  printf '#!/usr/bin/bash\n: > "%s/%s"\nexit 0\n' "$markers" "$name" > "$evil/$name"
  chmod 755 "$evil/$name"
done
printf ': > "%s/BASH_ENV"\n' "$markers" > "$evil/bashenv"
printf 'open("%s/PYTHONSTARTUP","w")\n' "$markers" > "$evil/startup.py"
for module in json os site sitecustomize usercustomize selectors signal ctypes gzip hashlib; do
  printf 'open("%s/PYTHONPATH-%s","w")\n' "$markers" "$module" > "$evil/$module.py"
done

node=$(command -v node) || { echo "node is required to build the commands"; exit 2; }
commands=$("$node" -e '
  const fs = require("fs"), vm = require("vm")
  const ctx = vm.createContext({})
  vm.runInContext(fs.readFileSync(process.argv[1] + "/Hermes.js", "utf8").replace(/^\.pragma library\s*$/m, ""), ctx)
  const dir = process.argv[1]
  const list = [
    ["state-read", ctx.stateReadCommand(dir)],
    ["verify", ctx.verifyCommand(dir, [])],
    ["desktop-running", ctx.desktopRunningCommand(dir)],
    ["chat", ctx.chatCommand(dir, [], 60, 60, false)],
  ]
  for (const [name, argv] of list) console.log(name + "\t" + JSON.stringify(argv))
' "$repo")

status=0
while IFS=$'\t' read -r name json; do
  mapfile -d '' -t argv < <("$node" -e 'for (const a of JSON.parse(process.argv[1])) process.stdout.write(a + "\0")' "$json")
  printf 'Reply with the single word ok.' | env \
    PATH="$evil:/usr/bin:/bin" BASH_ENV="$evil/bashenv" ENV="$evil/bashenv" \
    PYTHONPATH="$evil" PYTHONSTARTUP="$evil/startup.py" PYTHONHOME="$evil" \
    LD_PRELOAD="$evil/nonexistent.so" HOME="$HOME" \
    "${argv[@]}" > "$work/$name.out" 2> "$work/$name.err"
  rc=$?
  printf '%-16s exit %s\n' "$name" "$rc"
done <<< "$commands"

if [ -n "$(ls -A "$markers")" ]; then
  echo "FAIL: planted executables or hooks ran: $(ls "$markers" | tr '\n' ' ')"
  status=1
else
  echo "ok: no planted executable, BASH_ENV/ENV hook, PYTHONPATH module or PYTHONSTARTUP ran"
fi
if grep -q "Reply with the single word" "$work"/*.err "$work"/*.out 2>/dev/null; then
  echo "FAIL: the stdin message was echoed into captured output"
  status=1
fi
exit "$status"
