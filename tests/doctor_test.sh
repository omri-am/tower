#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/tower-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fixture() {
  PROJECT="$TMP/$1"
  new_repo "$PROJECT"
  new_project "$PROJECT"
}

doctor() {
  "$ROOT/bin/tower-doctor" --from "$PROJECT" > "$TMP/doctor.out" 2>&1
}

has_finding() { grep -q "\[$1\]" "$TMP/doctor.out"; }

set_field() {
  local key="$1" value="$2"
  awk -v key="$key" -v value="$value" '
    index($0,key ":")==1 {$0=key ": " value}
    {print}
  ' "$PROJECT/.tower/tasks/T001-test.md" > "$TMP/card"
  mv "$TMP/card" "$PROJECT/.tower/tasks/T001-test.md"
}

fixture healthy
new_card "$PROJECT" T001
assert_true 'ready project has no recovery findings' doctor
assert_true 'healthy output is explicit' grep -q 'no issues found' "$TMP/doctor.out"
dispatch "$PROJECT" T001 --prep
assert_true 'healthy in-flight task is not assumed stuck' doctor
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
assert_true 'doctor resolves from a linked worktree' "$ROOT/bin/tower-doctor" --from "$WT"

fixture lock
mkdir "$PROJECT/.tower/.git/tower-dispatch.lock"
assert_false 'existing lock requires attention' doctor
assert_true 'lock is reported' has_finding dispatch-lock
assert_true 'lock uncertainty is explicit' grep -q 'cannot determine whether it is stale' "$TMP/doctor.out"
assert_true 'lock recovery names rmdir' grep -q rmdir "$TMP/doctor.out"
assert_true 'doctor does not remove lock' test -d "$PROJECT/.tower/.git/tower-dispatch.lock"

fixture stale-exclude
EXCLUDE="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-path info/exclude)"
printf '.tower/\n.tower-task\n' > "$EXCLUDE"
BEFORE="$(git hash-object "$EXCLUDE")"
mkdir "$TMP/doctor-tmp"
TMPDIR="$TMP/doctor-tmp" doctor
assert_status 'stale exclude pattern requires attention' "$?" 1
assert_eq 'stale exclude pattern is reported once' "$(grep -c '\[exclude-pattern\]' "$TMP/doctor.out")" 1
assert_true 'exclude fix names the one-line edit' grep -q 'replace .tower/ with .tower' "$TMP/doctor.out"
assert_eq 'doctor leaves the exclude file unchanged' "$(git hash-object "$EXCLUDE")" "$BEFORE"
assert_eq 'doctor removes its empty work tree' "$(ls -A "$TMP/doctor-tmp")" ''

PROJECT="$TMP/subdirectory-exclude"
new_repo "$PROJECT"
PROJECT="$PROJECT/services/api"
new_project "$PROJECT"
EXCLUDE="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-path info/exclude)"
printf '/services/api/.tower\n' > "$EXCLUDE"
assert_true 'anchored subdirectory exclude ignores the dispatch symlink' doctor
assert_false 'correct subdirectory exclude has no finding' has_finding exclude-pattern
printf '/services/api/.tower/\n' > "$EXCLUDE"
assert_false 'directory-only subdirectory exclude requires attention' doctor
assert_eq 'stale subdirectory exclude is reported once' "$(grep -c '\[exclude-pattern\]' "$TMP/doctor.out")" 1
assert_true 'subdirectory exclude fix names its anchored pattern' grep -Fq 'replace /services/api/.tower/ with /services/api/.tower' "$TMP/doctor.out"
printf '.tower\n' > "$EXCLUDE"
assert_true 'unanchored exclude ignores the subdirectory dispatch symlink' doctor
assert_false 'unanchored subdirectory exclude has no finding' has_finding exclude-pattern

fixture failing-exclude-check
mkdir "$TMP/failing-git"
cat > "$TMP/failing-git/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *' check-ignore '*) exit 128 ;; esac
exec "$(command -v git)" "\$@"
EOF
chmod +x "$TMP/failing-git/git"
PATH="$TMP/failing-git:$PATH" TMPDIR="$TMP/doctor-tmp" doctor
assert_status 'unrunnable exclude check requires attention' "$?" 1
assert_true 'unrunnable exclude check is reported' grep -q 'could not check whether .git/info/exclude ignores the .tower dispatch symlink (git check-ignore exited 128)' "$TMP/doctor.out"
assert_true 'unrunnable exclude check names the diagnostic command' grep -q 'check-ignore -v .tower to see the error' "$TMP/doctor.out"
assert_eq 'failed check still removes its empty work tree' "$(ls -A "$TMP/doctor-tmp")" ''

fixture blocked
new_card "$PROJECT" T001
set_field status blocked
assert_false 'blocked task requires attention' doctor
assert_true 'blocked card is reported' has_finding blocked
assert_true 'missing blocked handoff is reported' has_finding missing-handoff

fixture missing-branch
new_card "$PROJECT" T001
set_field status in-flight
assert_false 'in-flight card must identify its branch' doctor
assert_true 'missing branch field is reported' has_finding missing-branch
set_field branch tower/missing/T001
doctor
assert_true 'deleted branch is distinguished' has_finding unknown-branch

fixture missing-worktree
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm "$WT/.tower" "$WT/.tower-task"
git -C "$PROJECT" worktree remove "$WT"
assert_false 'active branch without a checkout requires recovery' doctor
assert_true 'missing worktree is reported' has_finding missing-worktree
assert_true 'recovery names the recorded branch' grep -q 'tower/root/T001-test' "$TMP/doctor.out"

fixture mismatches
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm "$WT/.tower"
mkdir "$WT/.tower"
echo T999 > "$WT/.tower-task"
assert_false 'wrong shared state requires recovery' doctor
assert_true 'wrong state directory is reported' has_finding state-mismatch
assert_true 'wrong task marker is reported' has_finding task-marker

fixture review
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
set_field status in-review
assert_false 'review needs PR and draft handoff' doctor
assert_true 'missing review PR is reported' has_finding missing-pr
assert_true 'missing draft is reported' has_finding missing-handoff
set_field pr '"42"'
echo draft > "$PROJECT/.tower/handoffs/T001-handoff.md"
assert_true 'complete in-review state is healthy' doctor

fixture merged
new_card "$PROJECT" T001
set_field status merged
set_field pr '"42"'
assert_false 'merged card needs handoff' doctor
assert_true 'missing final handoff is reported' has_finding missing-handoff
echo final > "$PROJECT/.tower/handoffs/T001-handoff.md"
assert_false 'unprocessed handoff requires attention' doctor
assert_true 'missing receipt is reported' has_finding pending-ingest
HASH="$(git hash-object "$PROJECT/.tower/handoffs/T001-handoff.md")"
awk -v hash="$HASH" '{print} /^pr:/ {print "ingested_handoff: " hash}' \
  "$PROJECT/.tower/tasks/T001-test.md" > "$TMP/card"
mv "$TMP/card" "$PROJECT/.tower/tasks/T001-test.md"
assert_true 'processed merged card needs no surviving worktree' doctor
echo corrected >> "$PROJECT/.tower/handoffs/T001-handoff.md"
assert_false 'changed handoff requires another ingest' doctor
assert_true 'changed content invalidates receipt' has_finding pending-ingest

git -C "$PROJECT/.tower" add .
git -C "$PROJECT/.tower" commit -q -m 'tower: fixture'
echo staged > "$PROJECT/.tower/design.md"
git -C "$PROJECT/.tower" add design.md
BEFORE="$(git -C "$PROJECT/.tower" rev-parse HEAD) $(git hash-object "$PROJECT/.tower/.git/index") $(git hash-object "$PROJECT/.tower/tasks/T001-test.md") $(git hash-object "$PROJECT/.tower/handoffs/T001-handoff.md")"
doctor
AFTER="$(git -C "$PROJECT/.tower" rev-parse HEAD) $(git hash-object "$PROJECT/.tower/.git/index") $(git hash-object "$PROJECT/.tower/tasks/T001-test.md") $(git hash-object "$PROJECT/.tower/handoffs/T001-handoff.md")"
assert_eq 'diagnosis preserves commit, index, card and handoff bytes' "$AFTER" "$BEFORE"

"$ROOT/bin/tower-doctor" --from "$TMP" > "$TMP/doctor.out" 2>&1
assert_status 'unresolved project preserves locator exit code' "$?" 3

fixture invalid
new_card "$PROJECT" T001
set_field status unknown
assert_false 'unknown card status is diagnosed' doctor
assert_true 'invalid card finding is readable' has_finding invalid-card
set_field id ../T001
doctor
assert_true 'invalid ID cannot escape handoff directory' has_finding invalid-card

fixture missing-link
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm "$WT/.tower"
assert_false 'missing state link requires attention' doctor
assert_true 'missing state link is distinguished from conflicting state' has_finding missing-state
assert_true 'missing link recovery uses ln without deleting files' grep -q 'ln -s' "$TMP/doctor.out"
mv "$WT" "$WT-moved"
doctor
assert_true 'missing registered directory is diagnosed' has_finding missing-checkout
new_repo "$WT"
doctor
assert_true 'replacement repository is diagnosed' has_finding foreign-checkout

fixture inplace
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep --in-place
assert_true 'in-place task needs no worktree marker' doctor

PROJECT="$TMP/tracked"
new_repo "$PROJECT"
"$ROOT/bin/tower-init" "$PROJECT" > /dev/null
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep --in-place
assert_true 'tracked state supports healthy in-place diagnosis' doctor

fixture 'monorepo'
mkdir -p "$PROJECT/services/api"
new_project "$PROJECT/services/api"
PROJECT="$PROJECT/services/api"
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
assert_true 'monorepo paths resolve inside the task worktree' doctor

fixture "quote's-project"
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
assert_true 'quoted project paths remain healthy' doctor

env TOWER_PROJECT_DIR="$TMP/missing" "$ROOT/bin/tower-doctor" --from "$PROJECT" > "$TMP/doctor.out" 2>&1
assert_status 'explicit project overrides stale environment' "$?" 0
(cd "$TMP/healthy" && "$ROOT/bin/tower-doctor") > "$TMP/doctor.out" 2>&1
assert_status 'no-argument invocation uses the current project' "$?" 0

PROJECT="$TMP/ambiguous"
new_repo "$PROJECT"
mkdir "$PROJECT/one" "$PROJECT/two"
new_project "$PROJECT/one"
new_project "$PROJECT/two"
doctor
assert_status 'ambiguous discovery retains locator exit code' "$?" 4

fixture duplicate-id
new_card "$PROJECT" T001
cp "$PROJECT/.tower/tasks/T001-test.md" "$PROJECT/.tower/tasks/T001-other.md"
assert_false 'duplicate id requires attention' doctor
assert_true 'duplicate id is reported' has_finding duplicate-id
assert_true 'duplicate id recovery names both files' grep -q 'T001-other.md' "$TMP/doctor.out"

fixture id-filename-mismatch
new_card "$PROJECT" T001
mv "$PROJECT/.tower/tasks/T001-test.md" "$PROJECT/.tower/tasks/T002-test.md"
assert_false 'filename not matching its id requires attention' doctor
assert_true 'id-filename mismatch is reported' has_finding id-filename-mismatch

PROJECT="$TMP/copy"
new_repo "$PROJECT"
"$ROOT/bin/tower-init" "$PROJECT" > /dev/null
git -C "$PROJECT" worktree add -q -b task "$TMP/copy-worktree"
rm -rf "$PROJECT/.tower"
PROJECT="$TMP/copy-worktree"
assert_false 'per-branch state copy is rejected' doctor
assert_true 'noncanonical copy has a distinct finding' has_finding state-copy

mkdir "$TMP/fake-codex"
REAL_MKTEMP="$(command -v mktemp)"
REAL_PYTHON3="$(command -v python3)"
cat > "$TMP/fake-codex/mktemp" <<EOF
#!/bin/bash
path="\$("$REAL_MKTEMP" "\$@")" || exit \$?
printf '%s\n' "\$path"
if [ "\$#" -eq 0 ]; then
  printf '%s\n' "\$path" >> "$TMP/mktemp.log"
fi
EOF
chmod +x "$TMP/fake-codex/mktemp"
cat > "$TMP/fake-codex/python3" <<EOF
#!/bin/bash
printf '%s\n' "\${PYTHONDONTWRITEBYTECODE:-unset}" >> "$TMP/python3.log"
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$TMP/fake-codex/python3"
cat > "$TMP/fake-codex/codex" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) workdir="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
case "$1" in tower-register) name=register ;; /bin/bash) name=git ;; python3) name=state-root ;; esac
if [ "$name" = "${FAKE_CODEX_FAIL:-}" ]; then
  printf '%s' "${FAKE_CODEX_STDOUT:-}"
  [ -z "${FAKE_CODEX_STDERR:-}" ] || printf '%s\n' "$FAKE_CODEX_STDERR" >&2
  exit "$FAKE_CODEX_STATUS"
fi
cd "$workdir" && exec "$@"
EOF
chmod +x "$TMP/fake-codex/codex"
export FAKE_CODEX_LOG="$TMP/codex.log"
unset PYTHONDONTWRITEBYTECODE
SANDBOX_PATH="$TMP/fake-codex:$ROOT/bin:$PATH"
sandbox_doctor() { "$ROOT/bin/tower-doctor" "$@" > "$TMP/doctor.out" 2>&1; }
stderr_files() {
  local created=0 left=0 path
  if [ -f "$TMP/mktemp.log" ]; then
    while IFS= read -r path; do
      created=$((created + 1))
      [ ! -e "$path" ] || left=$((left + 1))
    done < "$TMP/mktemp.log"
    rm "$TMP/mktemp.log"
  fi
  printf 'created %s, left %s\n' "$created" "$left"
}

fixture sandbox
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm -f "$FAKE_CODEX_LOG"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT"
assert_eq 'guard: no flag succeeds with healthy output' "$?:$(tail -1 "$TMP/doctor.out")" '0:tower-doctor: checked 1 card(s); no issues found'
assert_false 'guard: no flag runs no codex' test -e "$FAKE_CODEX_LOG"

rm -f "$TMP/mktemp.log" "$TMP/python3.log"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_eq 'sandbox probes pass' "$?:$(tail -1 "$TMP/doctor.out")" '0:tower-doctor: checked 1 card(s); no issues found'
assert_eq 'sandbox python runs write no bytecode' "$(sort -u "$TMP/python3.log")" 1
assert_eq 'pass line appears once' "$(grep -c 'codex sandbox (workspace): tower-register, git and the state root are reachable' "$TMP/doctor.out")" 1
assert_eq 'three sandbox commands run' "$(wc -l < "$FAKE_CODEX_LOG" | tr -d ' ')" 3
assert_eq 'register command is first' "$(sed -n 1p "$FAKE_CODEX_LOG")" "sandbox -c check_for_update_on_startup=false -P workspace -C $WT -- tower-register --help"
assert_eq 'git command is second' "$(sed -n 2p "$FAKE_CODEX_LOG")" "sandbox -c check_for_update_on_startup=false -P workspace -C $WT -- /bin/bash -c git rev-parse --show-toplevel"
assert_eq 'state root command is third' "$(sed -n 3p "$FAKE_CODEX_LOG")" "sandbox -c check_for_update_on_startup=false -P workspace -C $WT -- python3 -c import sys; sys.path.insert(0, sys.argv[1]); import tower_msg; print(tower_msg.runtime_root()) $ROOT/lib"
assert_eq 'passing check removes its stderr file' "$(stderr_files)" 'created 1, left 0'
PATH="$SANDBOX_PATH" sandbox_doctor --codex-sandbox workspace --from "$PROJECT"
assert_eq 'reverse flag order succeeds' "$?:$(tail -1 "$TMP/doctor.out")" '0:tower-doctor: checked 1 card(s); no issues found'
assert_true 'reverse flag order prints pass line' grep -q 'state root are reachable' "$TMP/doctor.out"
rm -f "$TMP/mktemp.log"

for FAIL in register git state-root; do
  case "$FAIL" in register|state-root) STATUS=126 ;; git) STATUS=1 ;; esac
  export FAKE_CODEX_FAIL="$FAIL" FAKE_CODEX_STATUS="$STATUS"
  export FAKE_CODEX_STDERR="first $FAIL error
second $FAIL error"
  rm -f "$FAKE_CODEX_LOG"
  PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
  assert_eq "$FAIL failure exits one" "$?:$(tail -1 "$TMP/doctor.out")" '1:tower-doctor: checked 1 card(s); 1 finding(s) need attention'
  assert_eq "$FAIL still runs all probes" "$(wc -l < "$FAKE_CODEX_LOG" | tr -d ' ')" 3
  assert_true "$FAIL finding appears" has_finding "sandbox-$FAIL"
  assert_eq "$FAIL is the only probe finding" "$(grep -c '^\[sandbox-' "$TMP/doctor.out")" 1
  assert_false "guard: $FAIL has no pass line" grep -q 'state root are reachable' "$TMP/doctor.out"
  assert_true "$FAIL reports first stderr line" grep -q "exited $STATUS, stderr: first $FAIL error" "$TMP/doctor.out"
  assert_false "guard: $FAIL omits second stderr line" grep -q "second $FAIL error" "$TMP/doctor.out"
  assert_true "$FAIL gives profile instructions" grep -q 'sandbox-access.md, then rerun. Doctor never edits the profile.' "$TMP/doctor.out"
  assert_eq "$FAIL removes its stderr file" "$(stderr_files)" 'created 1, left 0'
done
export FAKE_CODEX_FAIL=state-root FAKE_CODEX_STATUS=0 FAKE_CODEX_STDOUT=/wrong/root FAKE_CODEX_STDERR=''
REFERENCE="$(cd "$WT" && python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import tower_msg; print(tower_msg.runtime_root())' "$ROOT/lib")"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_eq 'state root mismatch exits one' "$?:$(tail -1 "$TMP/doctor.out")" '1:tower-doctor: checked 1 card(s); 1 finding(s) need attention'
assert_true 'state root mismatch has finding' has_finding sandbox-state-root
assert_true 'state root mismatch prints both roots' grep -Fq "/wrong/root instead of the unsandboxed $REFERENCE" "$TMP/doctor.out"
unset FAKE_CODEX_FAIL FAKE_CODEX_STATUS FAKE_CODEX_STDOUT FAKE_CODEX_STDERR

fixture sandbox-no-worktree
rm -f "$FAKE_CODEX_LOG"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_eq 'missing worktree exits one' "$?:$(tail -1 "$TMP/doctor.out")" '1:tower-doctor: checked 0 card(s); 1 finding(s) need attention'
assert_true 'missing worktree finding appears' has_finding sandbox-no-worktree
assert_false 'guard: missing worktree runs no codex' test -e "$FAKE_CODEX_LOG"
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
mv "$WT" "$WT-moved"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_eq 'missing registered directory exits one' "$?:$(tail -1 "$TMP/doctor.out")" '1:tower-doctor: checked 1 card(s); 2 finding(s) need attention'
assert_true 'missing registered directory has sandbox finding' has_finding sandbox-no-worktree
assert_false 'guard: missing registered directory runs no codex' test -e "$FAKE_CODEX_LOG"

fixture sandbox-no-codex
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
mkdir "$TMP/no-codex"
ln -s "$(command -v git)" "$TMP/no-codex/git"
NO_CODEX_PATH="$TMP/no-codex:/usr/bin:/bin"
assert_false 'guard: no-codex setup hides codex' env PATH="$NO_CODEX_PATH" /bin/bash -c 'command -v codex'
PATH="$NO_CODEX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_eq 'missing codex exits one' "$?:$(tail -1 "$TMP/doctor.out")" '1:tower-doctor: checked 1 card(s); 1 finding(s) need attention'
assert_true 'missing codex finding appears' has_finding sandbox-no-codex
assert_false 'guard: linked worktree remains available' has_finding sandbox-no-worktree

fixture sandbox-monorepo
mkdir -p "$PROJECT/services/api"
new_project "$PROJECT/services/api"
PROJECT="$PROJECT/services/api"
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm -f "$FAKE_CODEX_LOG"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_eq 'monorepo sandbox probes pass' "$?:$(tail -1 "$TMP/doctor.out")" '0:tower-doctor: checked 1 card(s); no issues found'
assert_eq 'monorepo commands use project subdirectory' "$(grep -Fc -- "-C $WT/services/api -- " "$FAKE_CODEX_LOG")" 3

new_repo "$TMP/sandbox-monorepo-missing"
mkdir -p "$TMP/sandbox-monorepo-missing/services/api"
new_project "$TMP/sandbox-monorepo-missing/services/api"
PROJECT="$TMP/sandbox-monorepo-missing/services/api"
WT="$TMP/sandbox-monorepo-missing-linked"
git -C "$TMP/sandbox-monorepo-missing" worktree add -q "$WT" -b sandbox-missing-project
assert_false 'guard: linked worktree lacks the project directory' test -d "$WT/services/api"
rm -f "$FAKE_CODEX_LOG"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_true 'missing monorepo project has sandbox-no-worktree' has_finding sandbox-no-worktree
assert_false 'guard: missing monorepo project runs no codex' test -e "$FAKE_CODEX_LOG"

new_repo "$TMP/sandbox-bare-source"
git clone -q --bare "$TMP/sandbox-bare-source" "$TMP/sandbox-bare.git"
git -C "$TMP/sandbox-bare.git" worktree add -q "$TMP/sandbox-bare-main" main
new_project "$TMP/sandbox-bare-main"
PROJECT="$TMP/sandbox-bare-main"
rm -f "$FAKE_CODEX_LOG"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_true 'bare main with one linked worktree has sandbox-no-worktree' has_finding sandbox-no-worktree
assert_false 'guard: bare main with one linked worktree runs no codex' test -e "$FAKE_CODEX_LOG"
git -C "$TMP/sandbox-bare.git" worktree add -q "$TMP/sandbox-bare-second" -b second
WT="$(git -C "$TMP/sandbox-bare.git" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm -f "$FAKE_CODEX_LOG"
PATH="$SANDBOX_PATH" sandbox_doctor --from "$PROJECT" --codex-sandbox workspace
assert_eq 'bare main uses second linked worktree for all probes' "$(grep -Fc -- "-C $WT -- " "$FAKE_CODEX_LOG"):$(wc -l < "$FAKE_CODEX_LOG" | tr -d ' ')" '3:3'
PATH="$SANDBOX_PATH" sandbox_doctor --codex-sandbox
assert_eq 'missing sandbox profile is usage error' "$?:$(cat "$TMP/doctor.out")" '1:usage: tower-doctor [--from <dir>] [--codex-sandbox <profile>]'
PATH="$SANDBOX_PATH" sandbox_doctor --from a --from b
assert_eq 'repeated from is usage error' "$?:$(cat "$TMP/doctor.out")" '1:usage: tower-doctor [--from <dir>] [--codex-sandbox <profile>]'

summary
