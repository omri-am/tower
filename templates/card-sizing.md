---
confirmed: no
boundaries_per_card: 1
max_owned_paths: 5
max_acceptance_criteria: 7
source: protocol default
---

# Card sizing

The limits above govern how the orchestrator cuts task cards for this project. They start as
the defaults from `Card size` in `PROTOCOL.md`.

`confirmed: no` means the orchestrator has not yet confirmed them with the owner. It does
that once, at its first session after `tower-init`, before writing any draft card — and then
never again unless the owner asks.

`source` records where the confirmed numbers came from: `protocol default`, an
`AGENTS.md`/`CLAUDE.md` instruction (quote it), or `owner` when the owner set them directly.
