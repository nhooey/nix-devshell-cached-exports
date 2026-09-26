#!/usr/bin/env bash
# SessionStart hook: makes the current project's cached devshell exports
# available to every Bash tool command in the session, by appending one
# eval line to $CLAUDE_ENV_FILE (Claude Code prepends that file's contents
# to each Bash command it runs). Refers to the command by name only: no
# store paths, no vendored copy, no `nix run`.
set -euo pipefail

if ! command -v nix-devshell-cached-exports >/dev/null 2>&1; then
  echo "nix-devshell-cached-exports: not found on PATH; install it with: nix profile install github:nhooey/nix-devshell-cached-exports" >&2
  exit 0
fi

if [ -z "${CLAUDE_ENV_FILE:-}" ]; then
  exit 0
fi

# shellcheck disable=SC2016 # literal text to write to CLAUDE_ENV_FILE, not an expansion here
line='command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports)"'

if [ ! -f "$CLAUDE_ENV_FILE" ] || ! grep -qF -- "$line" "$CLAUDE_ENV_FILE"; then
  printf '%s\n' "$line" >>"$CLAUDE_ENV_FILE"
fi

# Warm the cache in the background: a first capture takes seconds, and
# session start should not wait for it. The command's lock makes the first
# Bash command wait for this capture instead of starting a second one.
(nix-devshell-cached-exports </dev/null >/dev/null 2>&1 &)
