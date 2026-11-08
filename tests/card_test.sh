#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
. "$ROOT/tests/lib.sh"

export LC_ALL=C.UTF-8
CARD="$ROOT/bin/tower-card"

PROJECT="$(mktemp -d)"
trap 'rm -rf "$PROJECT"' EXIT
TASKS="$PROJECT/.tower/tasks"
mkdir -p "$TASKS"
export TOWER_PROJECT_DIR="$PROJECT"

cat > "$TASKS/T001-full-card.md" <<'CARD'
---
id: T001
title: Fully populated card
status: merged
depends_on: [T002, T003]
vendor: claude
branch: full-card
pr: "https://github.com/owner/repo/pull/15425"
---

## Goal

One paragraph of prose long enough that it must wrap across more than a single rendered row
inside the box at every supported width.

## Interfaces & decisions

- first decision
- second decision, long enough that its text runs past the end of one source line and then
  continues on an indented line
- third decision, with an indented example:
  ```
  example line one
      example line two, indented further and long enough that it wraps inside the box at width 80
  ```
  a note after the example, long enough that its text runs past the end of one source line
  and continues on a second line

A closing paragraph that names a pull request where the source line breaks before
#15804 and the number stays inside the paragraph.

## Acceptance criteria

- [x] done one
- [ ] pending two
- [ ] pending three, whose text runs past the end of one source line in the card and
      continues on an indented line

## Verification

```
tower-card T001 --plain | diff - <(sed -n '/^## Goal/,$p' .tower/tasks/T001-full-card.md)
```
CARD

cat > "$TASKS/T002-preamble.md" <<'CARD'
---
id: T002
title: Card with a checkpoint preamble
status: ready
depends_on: []
vendor: any
branch: ""
pr: ""
---

> Orchestrator checkpoint: resized after T001 landed.

## Goal

Prove the preamble is rendered.
* a star item
continues on a second line
# A top heading
### A sub heading
> a quote
| a | b |
1. a numbered step
CARD

cat > "$TASKS/T003-no-headings.md" <<'CARD'
---
id: T003
title: Card with no section headings
status: draft
depends_on: []
vendor: any
branch: ""
pr: ""
---

This card never got its headings but still carries content.
CARD

cat > "$TASKS/T004a-suffixed-id.md" <<'CARD'
---
id: T004a
title: Card whose id carries a lowercase suffix
status: blocked
depends_on: [T001]
vendor: codex
branch: suffixed
pr: "https://github.com/owner/repo/pull/1, https://github.com/owner/repo/pull/2, https://github.com/owner/repo/pull/3"
---

## CORRECTION 2026-08-27 THIS HEADING IS DELIBERATELY LONGER THAN ANY SUPPORTED BOX WIDTH

Long headings must wrap rather than widen the box.
CARD

NON_ASCII_PROJECT="$PROJECT/non-ascii"
NON_ASCII_TASKS="$NON_ASCII_PROJECT/.tower/tasks"
mkdir -p "$NON_ASCII_TASKS"
cat > "$NON_ASCII_TASKS/T005-non-ascii.md" <<'CARD'
---
id: T005
title: Card with an em dash — and a title long enough to clip at both eighty and sixty columns
status: ready
---

## Goal

Keep the em dash — in this card.
CARD

overflowing_rows() {
  local want="$1" text="$2" line bad=0
  while IFS= read -r line; do
    case "$line" in
      "│ "*"│") : ;;
      "│ "*) continue ;;
    esac
    [ ${#line} -eq "$want" ] || bad=$((bad + 1))
  done <<EOF
$text
EOF
  printf '%s' "$bad"
}

non_ascii_lines() {
  printf '%s\n' "$1" | LC_ALL=C tr -d '\t' | LC_ALL=C grep -c '[^ -~]'
}

run_bounded_card() {
  TOWER_PROJECT_DIR="$NON_ASCII_PROJECT" python3 - "$CARD" "$1" "$2" <<'PY'
import pathlib
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1], "T005"], capture_output=True, timeout=10)
except subprocess.TimeoutExpired:
    sys.exit(124)
pathlib.Path(sys.argv[2]).write_bytes(result.stdout)
pathlib.Path(sys.argv[3]).write_bytes(result.stderr)
sys.exit(result.returncode)
PY
}

card_body_of() {
  awk 'NR==1 && $0=="---" {n=1; next} n==1 && $0=="---" {n=2; next} n==2' "$1" | sed '/./,$!d'
}

rows_from() {
  printf '%s\n' "$1" | awk -v needle="$2" -v count="$3" '
    !found && index($0, needle) { found=1; left=count }
    left > 0 { print; left-- }
  '
}

for WIDTH in 80 72 60 52 46; do
  for ID in T001 T002 T003 T004a; do
    OUT="$(TOWER_CARD_WIDTH="$WIDTH" "$CARD" "$ID")"
    assert_eq "every row is $WIDTH wide for $ID" "$(overflowing_rows "$WIDTH" "$OUT")" "0"
  done
  BOARD="$(TOWER_CARD_WIDTH="$WIDTH" "$CARD")"
  WIDEST=0
  while IFS= read -r LINE; do
    [ ${#LINE} -le "$WIDEST" ] || WIDEST=${#LINE}
  done <<EOF
$BOARD
EOF
  assert_true "board fits $WIDTH" test "$WIDEST" -le "$WIDTH"
done

for WIDTH in 80 60; do
  BOX_OUT="$PROJECT/boxed-$WIDTH.out" BOX_ERR="$PROJECT/boxed-$WIDTH.err"
  LC_ALL=C TOWER_CARD_WIDTH="$WIDTH" run_bounded_card "$BOX_OUT" "$BOX_ERR"
  BOX_STATUS=$?
  assert_status "non-UTF-8 locale renders boxed card within 10 seconds at $WIDTH" "$BOX_STATUS" "0"
  if [ "$BOX_STATUS" = 0 ]; then
    assert_eq "every non-UTF-8 locale box row is $WIDTH wide" \
      "$(overflowing_rows "$WIDTH" "$(cat "$BOX_OUT")")" "0"
  fi
done

mkdir -p "$PROJECT/stub-bin"
cat > "$PROJECT/stub-bin/locale" <<'LOCALE'
#!/usr/bin/env bash
[ "$1" = charmap ] || exit 1
printf '%s\n' ANSI_X3.4-1968
LOCALE
chmod +x "$PROJECT/stub-bin/locale"
BOX_OUT="$PROJECT/unavailable.out" BOX_ERR="$PROJECT/unavailable.err"
LC_ALL=C.UTF-8 PATH="$PROJECT/stub-bin:$PATH" run_bounded_card "$BOX_OUT" "$BOX_ERR"
BOX_STATUS=$?
assert_status "missing UTF-8 locale exits with an error" "$BOX_STATUS" "1"
if [ "$BOX_STATUS" != 124 ]; then
  assert_eq "missing UTF-8 locale explains the requirement" "$(cat "$BOX_ERR")" \
    "tower-card: the boxed view needs a UTF-8 locale and none is available - install C.UTF-8 or use --plain"
  assert_empty "missing UTF-8 locale prints no box" "$(cat "$BOX_OUT")"
fi

assert_eq "plain body keeps non-ASCII bytes with LC_ALL=C" \
  "$(LC_ALL=C TOWER_PROJECT_DIR="$NON_ASCII_PROJECT" "$CARD" T005 --plain | tail -n +4 | cmp - <(card_body_of "$NON_ASCII_TASKS/T005-non-ascii.md") | wc -l | tr -d ' ')" "0"

FULL="$("$CARD" T001)"
assert_eq "acceptance criteria carry a done count" "$(printf '%s\n' "$FULL" | grep -c 'ACCEPTANCE CRITERIA  1/3')" "1"
assert_eq "checked criteria render as filled boxes" "$(printf '%s\n' "$FULL" | grep -c '☑ done one')" "1"
assert_eq "unchecked criteria render as empty boxes" "$(printf '%s\n' "$FULL" | grep -c '☐ pending two')" "1"
assert_eq "a pull url renders as its number" "$(printf '%s\n' "$FULL" | grep -c 'pr: #15425')" "1"
assert_eq "fenced verification keeps its line intact" \
  "$(printf '%s\n' "$FULL" | grep -c "tower-card T001 --plain | diff - <(sed -n '/\^## Goal/,\$p' .tower/tasks/T001-full-card.md)")" "1"

FULL80="$(TOWER_CARD_WIDTH=80 "$CARD" T001)"
assert_eq "the goal fills its rows" \
  "$(rows_from "$FULL80" "One paragraph of prose" 3)" \
  "$(printf '%s\n' \
    '│   One paragraph of prose long enough that it must wrap across more than a    │' \
    '│   single rendered row inside the box at every supported width.               │' \
    '├──────────────────────────────────────────────────────────────────────────────┤')"
assert_eq "a bullet block start stays a row of its own" \
  "$(rows_from "$FULL80" "• first decision" 3)" \
  "$(printf '%s\n' \
    '│   • first decision                                                           │' \
    '│   • second decision, long enough that its text runs past the end of one      │' \
    '│     source line and then continues on an indented line                       │')"
assert_eq "a hard-wrapped bullet fills its rows" \
  "$(rows_from "$FULL80" "• second decision" 3)" \
  "$(printf '%s\n' \
    '│   • second decision, long enough that its text runs past the end of one      │' \
    '│     source line and then continues on an indented line                       │' \
    '│   • third decision, with an indented example:                                │')"
assert_eq "a hard-wrapped criterion fills its rows" \
  "$(rows_from "$FULL80" "☐ pending three" 3)" \
  "$(printf '%s\n' \
    '│   ☐ pending three, whose text runs past the end of one source line in the    │' \
    '│     card and continues on an indented line                                   │' \
    '├──────────────────────────────────────────────────────────────────────────────┤')"
assert_eq "guard: an indented fence renders as on origin/main" \
  "$(rows_from "$FULL80" "• third decision" 6)" \
  "$(printf '%s\n' \
    '│   • third decision, with an indented example:                                │' \
    '│     ```                                                                      │' \
    '│     example line one                                                         │' \
    '│         example line two, indented further and long enough that it wraps     │' \
    '│   inside the box at width 80                                                 │' \
    '│     ```                                                                      │')"
assert_eq "the line after an indented fence starts its own block and keeps its indent" \
  "$(rows_from "$FULL80" "a note after the example" 3)" \
  "$(printf '%s\n' \
    '│     a note after the example, long enough that its text runs past the end    │' \
    '│     of one source line and continues on a second line                        │' \
    '│                                                                              │')"
assert_eq "a line that starts with #<number> joins its paragraph" \
  "$(rows_from "$FULL80" "A closing paragraph" 3)" \
  "$(printf '%s\n' \
    '│   A closing paragraph that names a pull request where the source line        │' \
    '│   breaks before #15804 and the number stays inside the paragraph.            │' \
    '├──────────────────────────────────────────────────────────────────────────────┤')"

FULL60="$(TOWER_CARD_WIDTH=60 "$CARD" T001)"
assert_eq "an indented block's first row fills as wide as before" \
  "$(rows_from "$FULL60" "a note after the example" 4)" \
  "$(printf '%s\n' \
    '│     a note after the example, long enough that its text  │' \
    '│     runs past the end of one source line and continues   │' \
    '│     on a second line                                     │' \
    '│                                                          │')"
assert_eq "each block start begins its own row" \
  "$(rows_from "$(TOWER_CARD_WIDTH=80 "$CARD" T002)" "Prove the preamble is rendered." 8)" \
  "$(printf '%s\n' \
    '│   Prove the preamble is rendered.                                            │' \
    '│   • a star item continues on a second line                                   │' \
    '│   # A top heading                                                            │' \
    '│   ### A sub heading                                                          │' \
    '│   > a quote                                                                  │' \
    '│   | a | b |                                                                  │' \
    '│   1. a numbered step                                                         │' \
    '╰──────────────────────────────────────────────────────────────────────────────╯')"

PREAMBLE="$("$CARD" T002)"
assert_eq "content before the first heading is rendered" \
  "$(printf '%s\n' "$PREAMBLE" | grep -c 'Orchestrator checkpoint: resized after T001 landed.')" "1"

HEADLESS="$("$CARD" T003)"
assert_eq "a card with no headings renders its body" \
  "$(printf '%s\n' "$HEADLESS" | grep -c 'This card never got its headings but still carries content.')" "1"

assert_eq "a long heading wraps instead of widening the box" \
  "$(printf '%s\n' "$("$CARD" T004a)" | grep -c 'CORRECTION 2026-08-27 THIS HEADING IS')" "1"

BOARD80="$(TOWER_CARD_WIDTH=80 "$CARD")"
assert_eq "board shows one row per card" "$(printf '%s\n' "$BOARD80" | grep -c '^T00')" "4"
assert_eq "board compacts several pull urls" "$(printf '%s\n' "$BOARD80" | grep -c '#1 +2')" "1"
assert_eq "board tallies statuses" "$(printf '%s\n' "$BOARD80" | grep -c '4 cards')" "1"

PLAIN_ALL="$("$CARD" --plain
"$CARD" T001 --plain
"$CARD" T002 --plain
"$CARD" T003 --plain
"$CARD" T004a --plain)"
assert_eq "plain output is pure ascii" "$(non_ascii_lines "$PLAIN_ALL")" "0"

assert_eq "plain body is byte-identical to the card file" \
  "$("$CARD" T001 --plain | tail -n +4 | diff - <(card_body_of "$TASKS/T001-full-card.md") | wc -l | tr -d ' ')" "0"

assert_eq "plain board never truncates a title" \
  "$("$CARD" --plain | grep -c 'Card whose id carries a lowercase suffix')" "1"

"$CARD" t004a >/dev/null 2>&1
assert_status "an id matches case-insensitively" "$?" "0"

"$CARD" T404 >/dev/null 2>&1
assert_status "an unknown id fails" "$?" "1"

"$CARD" T001 T404 >/dev/null 2>&1
assert_status "a known id alongside an unknown one still fails" "$?" "1"

assert_eq "two ids render two cards" "$(printf '%s\n' "$("$CARD" T001 T002)" | grep -c '^╭─')" "2"

EMPTY_PROJECT="$(mktemp -d)"
mkdir -p "$EMPTY_PROJECT/.tower/tasks"
TOWER_PROJECT_DIR="$EMPTY_PROJECT" "$CARD" >/dev/null 2>&1
assert_status "a project with no cards fails" "$?" "1"
rm -rf "$EMPTY_PROJECT"

AMBIGUOUS_PROJECT="$(mktemp -d)"
mkdir -p "$AMBIGUOUS_PROJECT/.tower/tasks"
printf -- '---\nid: T900\nstatus: ready\n---\nbody\n' > "$AMBIGUOUS_PROJECT/.tower/tasks/T900-a.md"
printf -- '---\nid: T900\nstatus: ready\n---\nbody\n' > "$AMBIGUOUS_PROJECT/.tower/tasks/T900-b.md"
AMBIGUOUS_OUT="$(TOWER_PROJECT_DIR="$AMBIGUOUS_PROJECT" "$CARD" T900 --plain 2>&1)"
AMBIGUOUS_STATUS=$?
assert_status "an ambiguous id fails instead of guessing" "$AMBIGUOUS_STATUS" "1"
assert_eq "ambiguous id names every matching file" \
  "$(printf '%s\n' "$AMBIGUOUS_OUT" | grep -c 'T900-a.md\|T900-b.md')" "2"
rm -rf "$AMBIGUOUS_PROJECT"

EDGE_PROJECT="$(mktemp -d)"
mkdir -p "$EDGE_PROJECT/.tower/tasks"
DEEP32="$(printf '%32s' '')" DEEP33="$(printf '%33s' '')"
printf -- '---\nid: T950\ntitle: Edge cases\nstatus: draft\n---\n\n## Goal\n\n%s\n%s\n\n%s\n%s\n%s\n\n%s\n%s\n%s\n\n%s\n\n%s\n' \
  'A line that ends with a space ' 'joins the next line with one space.' \
  'First paragraph ends here.' '   ' 'Second paragraph starts here.' \
  'These join:' '**bold** text' '--plain text.' \
  "${DEEP32}kept at the limit" "${DEEP33}deeply indented words stay visible" > "$EDGE_PROJECT/.tower/tasks/T950-edge.md"
EDGE80="$(TOWER_PROJECT_DIR="$EDGE_PROJECT" TOWER_CARD_WIDTH=80 "$CARD" T950)"
EDGE46="$(TOWER_PROJECT_DIR="$EDGE_PROJECT" TOWER_CARD_WIDTH=46 "$CARD" T950)"
assert_eq "a trailing space joins with one space" \
  "$(rows_from "$EDGE80" "A line that ends with a space" 2)" \
  "$(printf '%s\n' \
    '│   A line that ends with a space joins the next line with one space.          │' \
    '│                                                                              │')"
assert_eq "guard: a line of spaces separates paragraphs as on origin/main" \
  "$(rows_from "$EDGE80" "First paragraph ends here." 3)" \
  "$(printf '%s\n' \
    '│   First paragraph ends here.                                                 │' \
    '│                                                                              │' \
    '│   Second paragraph starts here.                                              │')"
assert_eq "a line that starts with ** or -- continues its paragraph" \
  "$(rows_from "$EDGE80" "These join:" 2)" \
  "$(printf '%s\n' \
    '│   These join: **bold** text --plain text.                                    │' \
    '│                                                                              │')"
assert_eq "an indent that leaves 8 columns of text is kept" \
  "$(rows_from "$EDGE46" "kept" 4)" \
  "$(printf '│ %-42s │\n' "  ${DEEP32}kept at" "  ${DEEP32}the" "  ${DEEP32}limit" '')"
assert_eq "guard: an indent that leaves 7 columns of text renders as on origin/main" \
  "$(rows_from "$EDGE46" "deeply" 3)" \
  "$(printf '│ %-42s │\n' "  ${DEEP33}deeply" '  indented words stay visible'
    printf '%s\n' '╰────────────────────────────────────────────╯')"
rm -rf "$EDGE_PROJECT"

summary
