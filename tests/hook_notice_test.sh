#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

HOOK="$ROOT/hooks/tower-version-notice.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REMOTE="$TMP/remote"
git init -q "$REMOTE"
git -C "$REMOTE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REMOTE" tag v99.1.0

CACHE="$TMP/cache"
mkdir -p "$CACHE"
printf '%s\n99.1.0\n' "$(date +%s)" > "$CACHE/version-check"

run_hook() {
  env HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$ROOT" TOWER_CACHE_DIR="$CACHE" \
      TOWER_VERSION_REMOTE="$REMOTE" "$@" bash "$HOOK" 2>/dev/null
}

OUT="$(cd "$TMP" && run_hook env X=1)"
assert_eq "hook emits SessionStart json" "$(printf '%s' "$OUT" | grep -c '"hookEventName":"SessionStart"')" "1"
assert_eq "hook carries the notice text" "$(printf '%s' "$OUT" | grep -c '99\.1\.0 available')" "1"
assert_eq "hook output is one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "hook output is valid json" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")')" "ok"
fi

printf '%s\n0.0.1\n' "$(date +%s)" > "$CACHE/version-check"
OUT="$(cd "$TMP" && run_hook env X=1)"
assert_empty "no update means no output" "$OUT"

OUT="$(cd "$TMP" && run_hook env TOWER_NO_VERSION_CHECK=1)"
assert_empty "opt-out silences the hook" "$OUT"

OUT="$(cd "$TMP" && env HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$TMP/gone" bash "$HOOK" 2>/dev/null)"
assert_empty "bad plugin root produces no output" "$OUT"
assert_status "bad plugin root still exits 0" \
  "$(cd "$TMP" && env HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$TMP/gone" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0"

NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
for TOOL in bash env sed tr printf; do
  TOOLPATH="$(type -P "$TOOL" 2>/dev/null)"
  [ -n "$TOOLPATH" ] && ln -sf "$TOOLPATH" "$NOJQ/$TOOL"
done

CTRLROOT="$TMP/ctrlroot"
mkdir -p "$CTRLROOT/bin"
cat > "$CTRLROOT/bin/tower-version-check" <<'EOF'
#!/usr/bin/env bash
printf 'tower: 1.2.0 available (control\tchar\rhere) -> pull\n' >&2
EOF
chmod +x "$CTRLROOT/bin/tower-version-check"

OUT="$(env -i PATH="$NOJQ" HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$CTRLROOT" bash "$HOOK" 2>/dev/null)"
assert_eq "sed fallback: control-char notice stays one line" \
  "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "sed fallback: control-char notice is valid json" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")')" "ok"
fi

QUOTEROOT="$TMP/quoteroot"
mkdir -p "$QUOTEROOT/bin"
cat > "$QUOTEROOT/bin/tower-version-check" <<'EOF'
#!/usr/bin/env bash
printf 'tower: 1.2.0 available (path "C:\\Users\\test") -> pull\n' >&2
EOF
chmod +x "$QUOTEROOT/bin/tower-version-check"

OUT="$(env -i PATH="$NOJQ" HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$QUOTEROOT" bash "$HOOK" 2>/dev/null)"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "sed fallback: quote-and-backslash notice is valid json" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")')" "ok"
  assert_eq "sed fallback: quote-and-backslash message text survives" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["hookSpecificOutput"]["additionalContext"])')" \
    'tower: 1.2.0 available (path "C:\Users\test") -> pull'
fi

assert_eq "hooks.json registers exactly one event" \
  "$(grep -c '"SessionStart"' "$ROOT/hooks/hooks.json")" "1"
assert_eq "hooks.json uses CLAUDE_PLUGIN_ROOT" \
  "$(grep -c 'CLAUDE_PLUGIN_ROOT' "$ROOT/hooks/hooks.json")" "2"
assert_eq "hooks.json registers one permission notification" \
  "$(grep -c '"Notification"' "$ROOT/hooks/hooks.json")" "1"
assert_eq "permission notification matcher" \
  "$(grep -c '"matcher": "permission_prompt"' "$ROOT/hooks/hooks.json")" "1"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "hooks.json is valid json" \
    "$(python3 -c 'import json;json.load(open("'"$ROOT"'/hooks/hooks.json"));print("ok")')" "ok"
  assert_eq "Notification entry matches permission prompts" \
    "$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]["Notification"]; print(len(h) == 1 and h[0]["matcher"] == "permission_prompt")' "$ROOT/hooks/hooks.json")" "True"
fi

PERMISSION_HOOK="$ROOT/hooks/implementor-permission-notify.sh"
NOTICE="$TMP/permission-notice"
cat > "$NOTICE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$NOTICE_ARGS"
exit "${NOTICE_EXIT:-0}"
EOF
chmod +x "$NOTICE"
mkdir "$TMP/no-project" "$TMP/project"
mkdir "$TMP/project/.tower"
printf 'T002\n' > "$TMP/project/.tower-task"

run_permission_hook() {
  local project_dir="$1" payload="$2"
  shift 2
  rm -f "$TMP/notice.args"
  (cd "$project_dir" && printf '%s' "$payload" | env -u TOWER_TASK -u TOWER_PROJECT_DIR \
    TOWER_NOTIFY_COMMAND="$NOTICE" NOTICE_ARGS="$TMP/notice.args" "$@" \
    bash "$PERMISSION_HOOK") > "$TMP/hook.out" 2> "$TMP/hook.err"
  HOOK_STATUS=$?
}

run_permission_hook "$TMP/no-project" '{"notification_type":"permission_prompt"}' TOWER_TASK=T001
assert_eq "permission prompt notifies once" "$(cat "$TMP/notice.args")" \
  "$(printf 'tower: permission prompt\nT001 waits for your approval in its session')"
assert_eq "permission prompt exits 0" "$HOOK_STATUS" "0"
assert_empty "permission prompt has no stdout" "$(cat "$TMP/hook.out")"

run_permission_hook "$TMP/no-project" '{"notification_type": "permission_prompt"}' TOWER_TASK=T001
assert_eq "spaced permission prompt notifies once" "$(cat "$TMP/notice.args")" \
  "$(printf 'tower: permission prompt\nT001 waits for your approval in its session')"

run_permission_hook "$TMP/no-project" '{"notification_type":"idle_prompt"}' TOWER_TASK=T001
assert_eq "idle prompt does not notify" "$(test -e "$TMP/notice.args" && echo called || echo silent)" "silent"
assert_eq "idle prompt exits 0" "$HOOK_STATUS" "0"

run_permission_hook "$TMP/no-project" '{"notification_type":"permission_prompt"}'
assert_eq "no task does not notify" "$(test -e "$TMP/notice.args" && echo called || echo silent)" "silent"
assert_eq "no task exits 0" "$HOOK_STATUS" "0"

run_permission_hook "$TMP/project" '{"notification_type":"permission_prompt"}'
assert_eq "project marker supplies task" "$(cat "$TMP/notice.args")" \
  "$(printf 'tower: permission prompt\nT002 waits for your approval in its session')"

run_permission_hook "$TMP/no-project" '{"notification_type":"permission_prompt"}' TOWER_TASK=T001 NOTICE_EXIT=1
assert_eq "failing notify leaves hook successful" "$HOOK_STATUS" "0"
assert_empty "failing notify has no stdout" "$(cat "$TMP/hook.out")"

summary
