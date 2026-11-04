#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
. "$ROOT/tests/lib.sh"

export LC_CTYPE=UTF-8
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

summary
