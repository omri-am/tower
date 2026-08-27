---
description: Link tower's shell commands into ~/.local/bin through the resolver shim
allowed-tools: Bash
---

Run `"${CLAUDE_PLUGIN_ROOT}/bin/tower-bootstrap"` with the Bash tool and show the user its
output verbatim. If the output asks for a PATH line, tell the user to add that line to their
shell profile; do not edit their profile yourself. Do not re-run the command more than once.
