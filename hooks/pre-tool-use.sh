#!/usr/bin/env bash
# PreToolUse hook for Bash: when a command runs something through
# `nix develop --command` (or `nix-shell --run`) on the current directory's
# devshell, which the plugin already loads, reminds Claude that it costs
# seconds per call and is not needed. A reminder only: the command still
# runs, since another flake or devshell output can be a good reason.
set -euo pipefail

command -v nix-devshell-cached-exports >/dev/null 2>&1 || exit 0

# The command, as JSON text: matching the raw input avoids needing jq, and
# these words come through JSON encoding unchanged.
input=$(cat)
grep -qE 'nix develop( +(\.|path:\.))? +(-c|--command) |nix-shell( +(shell|default)\.nix)? +--(run|command) ' \
  <<<"$input" || exit 0

dir=$(grep -oE '"cwd": *"[^"\\]*"' <<<"$input" | head -1 | sed -E 's/^"cwd": *"//; s/"$//') || true
key=$(nix-devshell-cached-exports --print-key ${dir:+--dir "$dir"} </dev/null 2>/dev/null) || exit 0
[ -n "$key" ] || exit 0

# Plain text without quotes or backslashes, so it goes into the JSON as is.
context="This Bash command already starts with this directory's Nix devshell loaded \
(the nix-devshell-cached-exports plugin), so nix develop --command or nix-shell --run \
only adds seconds per call. Run the tool directly next time, unless you need a \
different flake or devshell output."

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$context"
