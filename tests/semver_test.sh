#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/lib/tower-semver.sh"

assert_eq "strip leading v" "$(semver_strip v1.2.3)" "1.2.3"
assert_eq "strip prerelease" "$(semver_strip 1.2.3-rc1)" "1.2.3"
assert_eq "strip build" "$(semver_strip 1.2.3+abc)" "1.2.3"
assert_eq "strip plain" "$(semver_strip 1.2.3)" "1.2.3"

assert_false "equal is not greater" semver_gt 1.2.3 1.2.3
assert_true  "patch greater" semver_gt 1.2.4 1.2.3
assert_false "patch lesser" semver_gt 1.2.3 1.2.4
assert_true  "minor greater" semver_gt 1.3.0 1.2.9
assert_false "minor lesser" semver_gt 1.2.9 1.3.0
assert_true  "major greater" semver_gt 2.0.0 1.9.9
assert_false "major lesser" semver_gt 1.9.9 2.0.0
assert_true  "short vs long" semver_gt 1.3 1.2.9
assert_false "long vs short" semver_gt 1.2.9 1.3
assert_true  "v prefix both sides" semver_gt v0.4.0 v0.3.1
assert_true  "ten beats nine numerically" semver_gt 0.10.0 0.9.0

assert_status "junk left" "$(semver_gt abc 1.0.0; echo $?)" "2"
assert_status "junk right" "$(semver_gt 1.0.0 abc; echo $?)" "2"
assert_status "empty left" "$(semver_gt "" 1.0.0; echo $?)" "2"

assert_eq "max picks highest" "$(printf '0.1.0\n0.10.0\n0.9.0\n' | semver_max)" "0.10.0"
assert_eq "max strips v" "$(printf 'v1.0.0\nv1.0.1\n' | semver_max)" "1.0.1"
assert_eq "max skips junk" "$(printf 'junk\n1.0.0\n' | semver_max)" "1.0.0"
assert_empty "max of nothing" "$(printf '' | semver_max)"

summary
