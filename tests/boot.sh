#!/usr/bin/env bash
# Boot tests: boot each image under QEMU (always under `timeout`), wait for
# its lines, type keys, and compare the transcript and QEMU's exit status
# with tests/expected/NAME.txt and the status given for the case.
#
# A case is a list of steps, run in order:
#   wait:TEXT   wait (up to STEP_TIMEOUT seconds) until TEXT appears in the
#               output after the point the previous wait matched
#   send:KEYS   type KEYS on the guest's serial port
# Waiting from the previous match on is what keeps the transcripts exact:
# the next key is only typed once the kernel has finished answering the
# last one.
#
# QEMU runs with -icount: the guest's clock then advances with the
# instructions it executes (2^ICOUNT_SHIFT ns each), not with the host's
# clock, so a timer interrupt lands at the same instruction on every run,
# however busy the host is or however long QEMU takes to translate code
# the first time it runs. Without it, a slow host can let a tick fall in
# the middle of a burst of task switches, and the schedule trace would
# group them differently.
#
# What still depends on the host is masked in the transcript: tick numbers
# after the demo (keys arrive whenever the host types them), and the
# switch and preemption counts, the counter's value and its run count,
# which follow from those.
#
# usage: tests/boot.sh [BUILD_DIR]      (default: build)
#        UPDATE=1 tests/boot.sh         rewrite tests/expected/ from this run
#                                       (read `git diff` before committing)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="${1:-build}"
TIMEOUT="${BOOT_TIMEOUT:-60}"
STEP_TIMEOUT="${STEP_TIMEOUT:-30}"
ICOUNT_SHIFT="${ICOUNT_SHIFT:-3}"
TMP="$(mktemp -d)"
trap 'exec 3>&- 2>/dev/null; rm -rf "$TMP"' EXIT

# The last tick of the demo (DEMO_END in source/demo/monitor.lpfree).
DEMO_END=110

pass=0
fail=0

normalize() {
    tr -d '\r' | awk -v end="$DEMO_END" '
        {
            line = $0
            out = ""
            # "tick 292" -> "tick N" when 292 is after the demo.
            while (match(line, /tick +[0-9]+/)) {
                word = substr(line, RSTART, RLENGTH)
                n = word
                sub(/tick +/, "", n)
                if (n + 0 > end) {
                    word = "tick N"
                }
                out = out substr(line, 1, RSTART - 1) word
                line = substr(line, RSTART + RLENGTH)
            }
            line = out line
            if (line ~ /^quit at tick/) {
                sub(/: [0-9]+ switches, [0-9]+ preemptions, counter at [0-9]+$/,
                    ": N switches, N preemptions, counter at N", line)
            }
            if (line ~ /^ +[0-9]+  counter /) {
                sub(/[0-9]+$/, "N", line)
            }
            print line
        }'
}

# case NAME IMAGE ARCH STATUS STEP...
case_() {
    local name=$1 image=$2 arch=$3 want=$4
    shift 4
    local raw="$TMP/$name.raw" out="$TMP/$name.out" err="$TMP/$name.err"
    rm -f "$TMP/in"
    mkfifo "$TMP/in"
    : > "$raw"
    timeout "$TIMEOUT" "$ROOT/scripts/qemu.sh" "$arch" "$BUILD/$image-$arch.elf" \
        -icount "shift=$ICOUNT_SHIFT,sleep=off" < "$TMP/in" > "$raw" 2> "$err" &
    local pid=$!
    exec 3> "$TMP/in"
    local why="" cursor=0 step
    for step in "$@"; do
        case "$step" in
            wait:*)
                local text=${step#wait:} found="" deadline=$((SECONDS + STEP_TIMEOUT))
                while true; do
                    found=$(tail -c +$((cursor + 1)) "$raw" | grep -b -o -F -m 1 -- "$text" | head -n 1)
                    [ -n "$found" ] && break
                    if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$pid" 2>/dev/null; then
                        found=$(tail -c +$((cursor + 1)) "$raw" | grep -b -o -F -m 1 -- "$text" | head -n 1)
                        [ -n "$found" ] || why="never printed '$text'"
                        break
                    fi
                    sleep 0.1
                done
                if [ -n "$found" ]; then
                    cursor=$((cursor + ${found%%:*} + ${#text}))
                fi
                ;;
            send:*)
                printf '%s' "${step#send:}" >&3
                ;;
        esac
        [ -n "$why" ] && break
    done
    exec 3>&-
    [ -n "$why" ] && kill "$pid" 2>/dev/null
    wait "$pid"
    local status=$?
    normalize < "$raw" > "$out"
    if [ -n "$why" ]; then
        echo "FAIL $name: $why"
        sed 's/^/    /' "$out" "$err" | tail -20
        fail=$((fail + 1))
    elif [ "$status" -eq 124 ]; then
        echo "FAIL $name: QEMU did not exit within ${TIMEOUT}s"
        sed 's/^/    /' "$out" | tail -20
        fail=$((fail + 1))
    elif [ "$status" -ne "$want" ]; then
        echo "FAIL $name: exit status $status, expected $want"
        sed 's/^/    /' "$out" "$err" | tail -20
        fail=$((fail + 1))
    elif [ "${UPDATE:-0}" = 1 ]; then
        cp "$out" "$HERE/expected/$name.txt"
        echo "upd  $name (exit status $status)"
        pass=$((pass + 1))
    elif ! diff -u "$HERE/expected/$name.txt" "$out" > "$TMP/$name.diff"; then
        echo "FAIL $name: transcript differs from tests/expected/$name.txt"
        sed 's/^/    /' "$TMP/$name.diff"
        fail=$((fail + 1))
    else
        echo "ok   $name (exit status $status)"
        pass=$((pass + 1))
    fi
}

# The whole demo, then the schedule trace, the task table, a key that does
# nothing, and quit. The trace comes first: it ends with the task switches
# the keys cause, at ticks that depend on when they are typed, and only
# one of those is in it then.
DEMO=("wait:demo finished" "wait:q quit" "send:t" "wait:switches to normal-priority tasks"
    "send:p" "wait:tasks at tick" "wait:mutexes:" "send:x" "wait:does nothing"
    "wait:q quit" "send:q" "wait:quit at tick")

# The hog overruns its stack; the scheduler notices at its next switch.
OVERFLOW=("wait:demo finished" "wait:q quit" "send:o" "wait:PANIC" "wait:stack overflow")

# QEMU's exit status: x86_64 exits with (status << 1) | 1 | 0x20, aarch64
# with the status itself (appinfo.lpfree).
case_ demo-x86_64      sched    x86_64  33 "${DEMO[@]}"
case_ overflow-x86_64  sched    x86_64  37 "${OVERFLOW[@]}"
case_ selftest-x86_64  selftest x86_64  33 "wait:self-test:"

case_ demo-aarch64     sched    aarch64 0  "${DEMO[@]}"
case_ overflow-aarch64 sched    aarch64 2  "${OVERFLOW[@]}"
case_ selftest-aarch64 selftest aarch64 0  "wait:self-test:"

echo "boot tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
