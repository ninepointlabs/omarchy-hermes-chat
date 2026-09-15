#!/bin/bash
# Behavioural tests for bounded-run. Usage: bounded-run.test.sh /path/to/bounded-run
set -u
BR=${1:?path to bounded-run}
PY=(/usr/bin/python3 -I -S -B "$BR")
pass=0; failn=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s -- %s\n' "$1" "$2"; }
gone() { ! pgrep -f -- "$1" >/dev/null; }
run() { env -i PATH=/usr/bin LC_ALL=C "${PY[@]}" "$@"; }

out=$(run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/echo hi); rc=$?
[ "$out" = hi ] && [ $rc -eq 0 ] && ok "basic output" || bad "basic output" "rc=$rc out=$out"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/bash -c 'exit 3'; rc=$?
[ $rc -eq 3 ] && ok "exit status" || bad "exit status" "rc=$rc"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/bash -c 'kill -KILL $$'; rc=$?
[ $rc -eq 137 ] && ok "signal status" || bad "signal status" "rc=$rc"

start=$SECONDS
n=$(run --stdout-cap 100 --stderr-cap 100 --deadline 10 --grace 1 -- /usr/bin/yes 2>/dev/null | wc -c); rc=${PIPESTATUS[0]}
[ "$n" -eq 100 ] && [ $((SECONDS - start)) -le 3 ] && ok "stdout cap (n=$n)" || bad "stdout cap" "n=$n t=$((SECONDS - start))"
n=$(run --stdout-cap 100 --stderr-cap 100 --deadline 10 --grace 1 -- /usr/bin/yes; echo "rc=$?")
[ "${n##*rc=}" = 201 ] && ok "stdout cap exit 201" || bad "stdout cap exit" "${n##*rc=}"

n=$( { run --stdout-cap 100 --stderr-cap 50 --deadline 10 --grace 1 -- /usr/bin/bash -c 'yes >&2'; echo "rc=$?" >&3; } 3>&1 2>&1 >/dev/null )
rc=${n##*rc=}; body=${n%rc=*}
[ "$rc" = 202 ] && [ ${#body} -eq 50 ] && ok "stderr cap exit 202 (n=${#body})" || bad "stderr cap" "rc=$rc n=${#body}"

start=$SECONDS
run --stdout-cap 100 --stderr-cap 100 --deadline 1 --grace 1 -- /usr/bin/sleep 1001.1; rc=$?
[ $rc -eq 124 ] && [ $((SECONDS - start)) -le 3 ] && gone "sleep 1001.1" && ok "deadline" || bad "deadline" "rc=$rc t=$((SECONDS - start))"

start=$SECONDS
run --stdout-cap 100 --stderr-cap 100 --deadline 1 --grace 1 -- /usr/bin/bash -c 'trap "" TERM; /usr/bin/bash -c "trap \"\" TERM; exec /usr/bin/sleep 1001.2" & wait'; rc=$?
sleep 0.2
[ $rc -eq 124 ] && gone "sleep 1001.2" && [ $((SECONDS - start)) -le 5 ] && ok "TERM-ignoring grandchild killed" || bad "TERM-ignoring grandchild" "rc=$rc"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/bash -c '/usr/bin/setsid /usr/bin/sleep 1001.3 </dev/null >/dev/null 2>&1 & exit 0'; rc=$?
sleep 0.2
[ $rc -eq 0 ] && gone "sleep 1001.3" && ok "setsid-escaped leftover reaped" || bad "setsid-escaped leftover" "rc=$rc"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/bash -c '( ( /usr/bin/setsid /usr/bin/sleep 1001.4 & ) & ) ; exit 0' >/dev/null 2>&1; rc=$?
sleep 0.2
[ $rc -eq 0 ] && gone "sleep 1001.4" && ok "double-forked daemon reaped" || bad "double-fork" "rc=$rc"

start=$SECONDS
out=$(run --stdout-cap 100 --stderr-cap 100 --deadline 10 --grace 1 -- /usr/bin/bash -c '/usr/bin/sleep 1001.5 & echo done'); rc=$?
[ "$out" = done ] && [ $rc -eq 0 ] && [ $((SECONDS - start)) -le 3 ] && gone "sleep 1001.5" && ok "pipe-holding background does not hang" || bad "pipe holder" "rc=$rc out=$out t=$((SECONDS - start))"

out=$(printf 'secret-over-stdin' | run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/cat)
[ "$out" = secret-over-stdin ] && ok "stdin passthrough" || bad "stdin passthrough" "$out"

out=$(env -i PATH=/usr/bin FOO=bar BASH_ENV=/nonexistent/evil ENV=/x 'BASH_FUNC_ls%%=() { :; }' LD_PRELOAD=/x.so "${PY[@]}" --stdout-cap 1000 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/env)
[ "$out" = "$(printf 'PATH=/usr/bin\nFOO=bar')" ] && ok "environment exact, injection hooks stripped" || bad "env" "$out"

out=$(exec 7</dev/null; run --stdout-cap 1000 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/ls /proc/self/fd | tr '\n' ' ')
[ "$out" = "0 1 2 3 " ] && ok "no inherited fds leak (got: $out)" || bad "fd leak" "$out"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /nonexistent/bin/x 2>/dev/null; rc=$?
[ $rc -eq 127 ] && ok "not found 127" || bad "not found" "rc=$rc"
run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- sleep 1 2>/dev/null; rc=$?
[ $rc -eq 125 ] && ok "relative command refused (no PATH search)" || bad "relative" "rc=$rc"
run --stdout-cap 100 -- /usr/bin/true 2>/dev/null; rc=$?
[ $rc -eq 125 ] && ok "missing options refused" || bad "missing options" "rc=$rc"

run --stdout-cap 100 --stderr-cap 100 --deadline 0 --grace 1 -- /usr/bin/sleep 1001.6 & sup=$!
sleep 0.5; kill -TERM $sup; wait $sup; rc=$?
sleep 0.2
[ $rc -eq 143 ] && gone "sleep 1001.6" && ok "external TERM -> 143, job gone" || bad "external TERM" "rc=$rc"

/usr/bin/setsid /usr/bin/bash -c "env -i PATH=/usr/bin /usr/bin/python3 -I -S -B '$BR' --stdout-cap 10 --stderr-cap 10 --deadline 0 --grace 1 -- /usr/bin/sleep 1001.7 >/dev/null 2>&1 & /usr/bin/sleep 0.5"
sleep 2
gone "sleep 1001.7" && gone "bounded-run.*1001.7" && ok "parent death tears down job" || bad "parent death" "still running"

env -i PATH=/usr/bin LC_ALL=C /usr/bin/python3 -I -S -B "$BR" --stdout-cap 100 --stderr-cap 100 --deadline 0 --grace 1 -- /usr/bin/sleep 1001.9 & sup=$!
sleep 0.5; kill -KILL $sup; wait $sup 2>/dev/null
sleep 0.3
gone "sleep 1001.9" && ok "supervisor SIGKILLed -> command dies by parent-death signal" || bad "supervisor SIGKILL" "command survived"

race=$(dirname "$0")/bounded-run-race.py
if [ -f "$race" ]; then
  if /usr/bin/python3 -I -B "$race" "$BR"; then ok "race harness: no signal to a non-owned or reaped target"; else bad "race harness" "see output above"; fi
fi

if command -v strace >/dev/null; then
  log=$(mktemp)
  env -i PATH=/usr/bin strace -f -qq -o "$log" -e trace=kill,waitid,posix_spawn,clone,clone3 "${PY[@]}" --stdout-cap 100 --stderr-cap 100 --deadline 1 --grace 1 -- /usr/bin/bash -c 'trap "" TERM; /usr/bin/sleep 1001.8 & wait' >/dev/null 2>&1
  sup=$(head -1 "$log" | cut -d' ' -f1)
  leader=$(grep -m1 -E "^$sup +clone3?\(.*= [0-9]+$" "$log" | grep -oE '= [0-9]+$' | tr -dc 0-9)
  reap_line=$(grep -nE "^$sup +waitid\(P_PID, $leader, .*WEXITED\)" "$log" | grep -v WNOWAIT | grep -v WNOHANG | head -1 | cut -d: -f1)
  last_kill=$(grep -nE "^$sup +kill\(" "$log" | tail -1 | cut -d: -f1)
  if [ -n "$leader" ] && [ -n "$reap_line" ] && [ -n "$last_kill" ] && [ "$last_kill" -lt "$reap_line" ]; then
    ok "strace: every kill precedes reaping leader $leader (last kill line $last_kill < reap line $reap_line)"
  else
    bad "strace ordering" "leader=$leader reap=$reap_line last_kill=$last_kill log=$log"
  fi
else
  printf 'skip strace ordering (strace not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
