#!/usr/bin/env bash
# SubagentStart hook: tells each subagent started in a Nix project that its
# Bash commands already load the devshell, so it runs tools directly instead
# of paying seconds per call for `nix develop --command`, and how a command
# gets another checkout's environment. Says nothing outside a Nix project or
# without the command installed.
set -euo pipefail

command -v nix-devshell-cached-exports >/dev/null 2>&1 || exit 0

# The subagent's directory, from the hook input's "cwd" (no jq: a path with
# a quote or backslash in it falls back to this hook's own directory).
dir=$(grep -oE '"cwd": *"[^"\\]*"' | head -1 | sed -E 's/^"cwd": *"//; s/"$//') || true
key=$(nix-devshell-cached-exports --print-key ${dir:+--dir "$dir"} </dev/null 2>/dev/null) || exit 0
[ -n "$key" ] || exit 0

# Plain text without quotes or backslashes, so it goes into the JSON as is.
context="Every Bash command you run already has this project's Nix devshell loaded \
(by the nix-devshell-cached-exports plugin), for the directory the command starts in. \
Run the devshell's tools directly: wrapping them in nix develop --command costs seconds \
per call and gains nothing, since a change to the .nix files is picked up on the next \
command. A cd at the top level of a Bash command loads the new directory's devshell; \
a cd inside bash -c or a script does not, and the tools keep running from the previous \
checkout. To work in another checkout or worktree, cd there at the top level."

printf '{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"%s"}}\n' "$context"
