#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
mkdir "$TOOLS"
ln -s "$(type -P bash)" "$TOOLS/bash"

new_case() {
  CASE="$TMP/$1"
  mkdir "$CASE"
}

make_stub() {
  printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$@" > "$0.args"' "exit $2" > "$1"
  chmod +x "$1"
}

run_notice() {
  env -u DISPLAY -u WAYLAND_DISPLAY -u TOWER_NOTIFY_COMMAND PATH="$CASE:$TOOLS" "$@" > "$CASE/out" 2> "$CASE/err"
  STATUS=$?
}

record() {
  if [ -f "$1.args" ]; then cat "$1.args"; printf x; else printf none; fi
}

assert_fallback() {
  assert_eq "$1" "$(cat "$CASE/err"; printf x)" "$(printf 'tower: t: m\a\nx')"
}

new_case one
make_stub "$CASE/forward" 3
make_stub "$CASE/osascript" 4
make_stub "$CASE/notify-send" 5
run_notice DISPLAY=:0 TOWER_NOTIFY_COMMAND="$CASE/forward" "$ROOT/bin/tower-notify" t m
assert_eq 'channel 1 wins over osascript, notify-send and stderr' "$STATUS:$(record "$CASE/forward"):$(record "$CASE/osascript"):$(record "$CASE/notify-send"):$(cat "$CASE/err"; printf x)" "$(printf '3:tower: t\nm\nx:none:none:x')"

new_case quoted
make_stub "$CASE/forward" 0
run_notice TOWER_NOTIFY_COMMAND="$CASE/forward" "$ROOT/bin/tower-notify" 'it'\''s "x" $HOME' 'cost $5 "now" '\''ok'\'''
assert_eq 'channel 1 passes a quote, a space and $ unchanged' "$STATUS:$(record "$CASE/forward")" "$(printf '0:tower: it'\''s "x" $HOME\ncost $5 "now" '\''ok'\''\nx')"

new_case spaced
mkdir "$CASE/forward dir"
make_stub "$CASE/forward dir/forward" 0
run_notice TOWER_NOTIFY_COMMAND="$CASE/forward dir/forward" "$ROOT/bin/tower-notify" t m
assert_eq 'channel 1 runs a command path that contains a space' "$STATUS:$(record "$CASE/forward dir/forward")" "$(printf '0:tower: t\nm\nx')"

new_case empty
run_notice TOWER_NOTIFY_COMMAND= "$ROOT/bin/tower-notify" t m
assert_eq 'channel 1 is skipped when TOWER_NOTIFY_COMMAND is empty' "$STATUS:$(cat "$CASE/out"; printf x)" '0:x'
assert_fallback 'empty forwarder uses channel 4'

new_case applescript
make_stub "$CASE/osascript" 4
make_stub "$CASE/notify-send" 5
run_notice DISPLAY=:0 "$ROOT/bin/tower-notify" 'say "hi"' 'a "b"'
assert_eq "guard: channel 2 sends today's osascript notification" "$STATUS:$(record "$CASE/osascript"):$(record "$CASE/notify-send")" "$(printf '4:-e\n%s\nx:none' 'display notification "a \"b\"" with title "tower: say \"hi\"" sound name "Glass"')"

new_case display
make_stub "$CASE/notify-send" 5
run_notice DISPLAY=:0 "$ROOT/bin/tower-notify" t m
assert_eq 'channel 3 runs notify-send when DISPLAY is set' "$STATUS:$(record "$CASE/notify-send")" "$(printf '5:tower: t\nm\nx')"

new_case wayland
make_stub "$CASE/notify-send" 0
run_notice WAYLAND_DISPLAY=wayland-0 "$ROOT/bin/tower-notify" t m
assert_eq 'channel 3 runs notify-send when WAYLAND_DISPLAY is set' "$STATUS:$(record "$CASE/notify-send")" "$(printf '0:tower: t\nm\nx')"

new_case no_display
make_stub "$CASE/notify-send" 5
run_notice "$ROOT/bin/tower-notify" t m
assert_eq 'channel 3 needs a display' "$STATUS:$(record "$CASE/notify-send")" '0:none'
assert_fallback 'no display uses channel 4'

new_case empty_display
make_stub "$CASE/notify-send" 5
run_notice DISPLAY= "$ROOT/bin/tower-notify" t m
assert_eq 'channel 3 treats an empty DISPLAY as no display' "$STATUS:$(record "$CASE/notify-send")" '0:none'
assert_fallback 'empty display uses channel 4'

new_case empty_wayland
make_stub "$CASE/notify-send" 5
run_notice WAYLAND_DISPLAY= "$ROOT/bin/tower-notify" t m
assert_eq 'channel 3 treats an empty WAYLAND_DISPLAY as no display' "$STATUS:$(record "$CASE/notify-send")" '0:none'
assert_fallback 'empty WAYLAND_DISPLAY uses channel 4'

new_case no_notify_send
run_notice DISPLAY=:0 "$ROOT/bin/tower-notify" t m
assert_eq 'channel 3 needs notify-send on PATH' "$STATUS:$(cat "$CASE/out"; printf x)" '0:x'
assert_fallback 'a display without notify-send uses channel 4'

new_case fallback
run_notice "$ROOT/bin/tower-notify" t '100% \n done'
assert_eq 'channel 4 writes the notice and a bell to stderr' "$STATUS:$(cat "$CASE/out"; printf x):$(cat "$CASE/err"; printf x)" "$(printf '0:x:tower: t: 100%% \\n done\a\nx')"

new_case usage
make_stub "$CASE/forward" 0
run_notice TOWER_NOTIFY_COMMAND="$CASE/forward" "$ROOT/bin/tower-notify" t
assert_eq 'guard: one argument prints usage and runs no channel' "$STATUS:$(cat "$CASE/err"; printf x):$(record "$CASE/forward")" "$(printf '1:usage: tower-notify <title> <message>\nx:none')"
run_notice TOWER_NOTIFY_COMMAND="$CASE/forward" "$ROOT/bin/tower-notify"
assert_eq 'guard: zero arguments prints usage and runs no channel' "$STATUS:$(cat "$CASE/err"; printf x):$(record "$CASE/forward")" "$(printf '1:usage: tower-notify <title> <message>\nx:none')"

new_case watch
make_stub "$CASE/forward" 0
env TOWER_NOTIFY_COMMAND="$CASE/forward" bash "$ROOT/tests/watch_test.sh" > "$CASE/watch.log" 2>&1
STATUS=$?
assert_eq 'guard: watch_test.sh passes with TOWER_NOTIFY_COMMAND set and never runs it' "$STATUS:$(record "$CASE/forward")" '0:none'

summary
