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

# The plugin and the command are installed separately, so the command may
# predate --max-wait. With it, a Bash command waits at most MAX_WAIT seconds
# for a capture, then runs with the last good environment; without it, a
# capture holds up every Bash command until it finishes.
MAX_WAIT=10
args=
if nix-devshell-cached-exports --help 2>/dev/null | grep -qF -- --max-wait; then
  args=" --max-wait $MAX_WAIT"
fi

# stdin is closed so that nothing it runs (or anything else on PATH under its
# name) can wait on input and hold up every Bash command.
# shellcheck disable=SC2016 # literal text to write to CLAUDE_ENV_FILE, not an expansion here
load='eval "$(nix-devshell-cached-exports'"$args"' </dev/null)"'
# shellcheck disable=SC2016 # literal text to write to CLAUDE_ENV_FILE, not an expansion here
line='command -v nix-devshell-cached-exports >/dev/null 2>&1 && '"$load"
# The environment loads before the command runs, so in `cd other && cmd`
# the cd comes too late for it. This cd loads again for its new directory
# (in bash and zsh, the shells Claude Code runs commands in).
# shellcheck disable=SC2016 # literal text to write to CLAUDE_ENV_FILE, not an expansion here
cd_line='cd() { builtin cd "$@" || return; command -v nix-devshell-cached-exports >/dev/null 2>&1 && '"$load"'; return 0; }'

for l in "$line" "$cd_line"; do
  if [ ! -f "$CLAUDE_ENV_FILE" ] || ! grep -qF -- "$l" "$CLAUDE_ENV_FILE"; then
    printf '%s\n' "$l" >>"$CLAUDE_ENV_FILE"
  fi
done

# Warm the cache in the background: a first capture takes seconds, and
# session start should not wait for it. The command's lock makes the first
# Bash command wait for this capture instead of starting a second one.
(nix-devshell-cached-exports </dev/null >/dev/null 2>&1 &)
