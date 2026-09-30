#!/usr/bin/env bash
# End-to-end run of Coucou on Linux, on a virtual display.
#
# Starts the real app (a release build) under Xvfb (+ Mutter when installed),
# feeds it Claude Code hook events through the real coucou-hook relay, clicks
# the island like a person would, checks what Claude Code would have received,
# and records GIFs and screenshots of it all for pull requests.
#
#   windows/scripts/e2e/linux.sh [path/to/coucou] [output dir]
#
# Needs: Xvfb, xdotool, ffmpeg, dbus-launch; plus a compositor
# for real transparency — mutter (preferred, it is GNOME's) or picom.
# Nothing touches your own settings: HOME and XDG_RUNTIME_DIR are throwaway.
# Exits non-zero when any check fails.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
BIN=${1:-$here/../../target/release/coucou}
OUT=${2:-$here/../../e2e-out}
DISPLAY_NUM=${E2E_DISPLAY:-77}
W=1920 H=1080
# Where the island is drawn: a 720-wide panel at the top centre.
PANEL_X=$(( (W - 720) / 2 ))
CROP_W=900 CROP_H=230 CROP_X=$(( (W - 900) / 2 ))

[ -x "$BIN" ] || { echo "no app binary at $BIN — build it with: npx tauri build --no-bundle"; exit 2; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
work=$(mktemp -d)
mkdir -p "$work/home"
mkdir -m 700 "$work/run"
export HOME=$work/home XDG_RUNTIME_DIR=$work/run DISPLAY=:$DISPLAY_NUM
HOOK=$HOME/.local/share/coucou/bin/coucou-hook
LOG=$HOME/.local/share/coucou/coucou.log

pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
  cp "$LOG" "$OUT/coucou.log" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

failures=0
check() { # check "description" command...
  local what=$1; shift
  if "$@"; then echo "  ok    $what"; else echo "  FAIL  $what"; failures=$((failures + 1)); fi
}

# ── Display, window manager, app ──────────────────────────────────────────────
Xvfb ":$DISPLAY_NUM" -screen 0 "${W}x${H}x24" >/dev/null 2>&1 & pids+=($!)
sleep 1
eval "$(dbus-launch --sh-syntax)"
if command -v mutter >/dev/null; then
  mutter --x11 --replace >/dev/null 2>&1 & pids+=($!)
  sleep 2
elif command -v picom >/dev/null; then
  picom --backend xrender >/dev/null 2>&1 & pids+=($!)
  sleep 1
fi
# A wallpaper, so the transparent island reads as it does on a desktop.
command -v xsetroot >/dev/null && xsetroot -solid '#1d3557' || true

# Hooks already installed, as they would be for anyone using Coucou: the
# Claude Code card then shows the session rather than "Hooks not installed".
mkdir -p "$HOME/.claude"
events="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest PermissionDenied Notification Stop StopFailure SubagentStart SubagentStop"
{
  printf '{"hooks":{'
  sep=""
  for e in $events; do
    printf '%s"%s":[{"hooks":[{"type":"command","command":"\"%s\" %s"}]}]' "$sep" "$e" "$HOME/.local/share/coucou/bin/coucou-hook" "$e"
    sep=","
  done
  printf '}}\n'
} > "$HOME/.claude/settings.json"

"$BIN" > "$OUT/app-stdout.log" 2>&1 & pids+=($!)

rec_pid=
record() { # record name — until stop_recording
  ffmpeg -loglevel error -y -f x11grab -draw_mouse 0 -framerate 20 -video_size "${CROP_W}x${CROP_H}" \
    -i ":$DISPLAY_NUM+$CROP_X,0" -pix_fmt yuv420p "$work/$1.mp4" & rec_pid=$!
  rec_name=$1
}
stop_recording() {
  kill -INT "$rec_pid"; wait "$rec_pid" 2>/dev/null || true
  ffmpeg -loglevel error -y -i "$work/$rec_name.mp4" \
    -vf "fps=15,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    "$OUT/$rec_name.gif"
}
# Through ffmpeg, like the GIFs: it sees the composited screen, xwd does not.
shot() {
  ffmpeg -loglevel error -y -f x11grab -draw_mouse 0 -video_size "${CROP_W}x${CROP_H}" \
    -i ":$DISPLAY_NUM+$CROP_X,0" -frames:v 1 "$OUT/$1.png"
}
click() { xdotool mousemove "$1" "$2"; sleep 0.35; xdotool click 1; }
away() { xdotool mousemove 200 900; }
event() { printf '%s' "$1" | "$HOOK" >/dev/null; }
open_island() { xdotool mousemove $((W / 2)) 16; sleep 0.8; xdotool click 1; sleep 1.2; }

echo "Coucou e2e on :$DISPLAY_NUM — output in $OUT"

# ── 1. Launch: Mochi says hello ───────────────────────────────────────────────
away
record greeting
sleep 7
stop_recording
check "the relay was installed at launch" test -x "$HOOK"
check "the relay socket is private (0600)" \
  test "$(stat -c %a "$XDG_RUNTIME_DIR/coucou.sock")" = 600

# ── 2. A Claude Code session at work ──────────────────────────────────────────
S='"session_id":"demo-1","cwd":"/home/me/coucou"'
event "{\"hook_event_name\":\"SessionStart\",$S}"
sleep 1.5
open_island
away
record session
event "{\"hook_event_name\":\"UserPromptSubmit\",$S,\"prompt\":\"Add a Linux build\"}"; sleep 1.2
event "{\"hook_event_name\":\"PreToolUse\",$S,\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/home/me/coucou/README.md\"}}"; sleep 1.2
event "{\"hook_event_name\":\"PreToolUse\",$S,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/home/me/coucou/windows/src-tauri/src/pipe.rs\"}}"; sleep 1.2
event "{\"hook_event_name\":\"PreToolUse\",$S,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cargo test --workspace\"}}"; sleep 1.2
event "{\"hook_event_name\":\"PostToolUse\",$S,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cargo test --workspace\"}}"; sleep 0.6
shot session-working
event "{\"hook_event_name\":\"Stop\",$S}"; sleep 2
shot session-finished
stop_recording

# ── 3. Two sessions ask at once: the queue ────────────────────────────────────
sleep 5
record approvals
printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"alpha","cwd":"/home/me/alpha","tool_name":"Bash","tool_use_id":"toolu_a","tool_input":{"command":"npm test"}}' \
  | "$HOOK" > "$work/alpha.out" & alpha=$!
sleep 1
printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"beta","cwd":"/home/me/beta","tool_name":"Bash","tool_use_id":"toolu_b","tool_input":{"command":"rm -rf build"}}' \
  | "$HOOK" > "$work/beta.out" & beta=$!
sleep 1.5
shot approval-queue
away; sleep 1
click $((PANEL_X + 302)) 121   # Allow → alpha
wait $alpha || true
sleep 1.2
shot approval-second
click $((PANEL_X + 195)) 121   # Deny → beta
wait $beta || true
sleep 1.5
stop_recording
check "Allow on the island answers allow" grep -q '"behavior":"allow"' "$work/alpha.out"
check "Deny on the island answers deny" grep -q '"behavior":"deny"' "$work/beta.out"

# ── 4. Answered in the terminal: the card goes away ───────────────────────────
printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"gamma","cwd":"/home/me/gamma","tool_name":"Bash","tool_use_id":"toolu_c","tool_input":{"command":"make"}}' \
  | "$HOOK" > "$work/gamma.out" & gamma=$!
sleep 1.5
event '{"hook_event_name":"PermissionDenied","session_id":"gamma","cwd":"/home/me/gamma","tool_name":"Bash","tool_use_id":"toolu_c","tool_input":{"command":"make"}}'
wait $gamma || true
check "a request denied in the terminal releases the relay silently" test ! -s "$work/gamma.out"

# ── 5. Minimize with a request waiting, reopen, it is still there ─────────────
printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"delta","cwd":"/home/me/delta","tool_name":"Bash","tool_use_id":"toolu_d","tool_input":{"command":"git push"}}' \
  | "$HOOK" > "$work/delta.out" & delta=$!
sleep 1.5
click $((PANEL_X + 656)) 25   # the "–" button
sleep 1.2
shot minimized
open_island
shot reopened
click $((PANEL_X + 302)) 121
wait $delta || true
check "a request survives minimize and can still be allowed" grep -q '"behavior":"allow"' "$work/delta.out"

# ── 6. Coucou closed: Claude Code is never held up ────────────────────────────
kill "${pids[-1]}"; unset 'pids[-1]'
sleep 1
start=$(date +%s%N)
printf '%s' '{"hook_event_name":"PermissionRequest","session_id":"x","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | "$HOOK" > "$work/closed.out"
ms=$(( ($(date +%s%N) - start) / 1000000 ))
check "with Coucou closed the relay exits at once (${ms} ms) and prints nothing" \
  test "$ms" -lt 1000 -a ! -s "$work/closed.out"

echo
ls -1 "$OUT"
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
