#!/usr/bin/env bats
# Tests for hooks/session-start.sh, the plugin's SessionStart hook.
# Sandbox-safe: no network access, no writes outside $BATS_TEST_TMPDIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOOK="$REPO_ROOT/hooks/session-start.sh"

  STUB_DIR="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_DIR"

  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"

  cat >"$STUB_DIR/nix-devshell-cached-exports" <<EOF
#!/usr/bin/env bash
if [ "\${1-}" = --help ]; then
  printf '%s\n' "\${NDCE_STUB_HELP-}"
  exit 0
fi
sleep "\${NDCE_STUB_SLEEP:-0}"
echo called >>"$STUB_LOG"
echo 'export NDCE_STUB_OK=1'
EOF
  chmod +x "$STUB_DIR/nix-devshell-cached-exports"

  ENV_FILE="$BATS_TEST_TMPDIR/claude-env-file.sh"

  # A minimal PATH that does not include the stub, for the "absent" cases.
  BARE_PATH="/usr/bin:/bin"
}

# The hook warms the cache in the background; wait for the stub to log.
wait_for_calls() {
  local want=$1 i
  for i in $(seq 50); do
    [ "$(wc -l <"$STUB_LOG" 2>/dev/null || echo 0)" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

EXPECTED_LINE='command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports </dev/null)"'
EXPECTED_CD_LINE='cd() { builtin cd "$@" || return; command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports </dev/null)"; return 0; }'

@test "stub on PATH: eval line appended once across two runs, stub invoked for warm-up" {
  PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]

  [ -f "$ENV_FILE" ]
  [ "$(grep -cxF -- "$EXPECTED_LINE" "$ENV_FILE")" -eq 1 ]
  [ "$(grep -cxF -- "$EXPECTED_CD_LINE" "$ENV_FILE")" -eq 1 ]

  wait_for_calls 1
  first_count="$(wc -l <"$STUB_LOG")"

  # Run the hook a second time: the line must not be duplicated.
  PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]

  [ "$(grep -cxF -- "$EXPECTED_LINE" "$ENV_FILE")" -eq 1 ]
  [ "$(wc -l <"$ENV_FILE")" -eq 2 ]

  # The stub was invoked again for the second run's warm-up.
  wait_for_calls $((first_count + 1))
}

@test "warm-up runs in the background: the hook does not wait for it" {
  start=$(date +%s)
  NDCE_STUB_SLEEP=3 PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]
  [ $(($(date +%s) - start)) -lt 3 ]
  [ "$(grep -cxF -- "$EXPECTED_LINE" "$ENV_FILE")" -eq 1 ]
}

@test "command supports --max-wait: the eval lines pass it" {
  NDCE_STUB_HELP='  --max-wait SECONDS  ...' PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(cat "$ENV_FILE")" = 'command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports --max-wait 10 </dev/null)"
cd() { builtin cd "$@" || return; command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports --max-wait 10 </dev/null)"; return 0; }' ]
}

@test "the env file's cd loads again after changing directory, and keeps cd's status" {
  PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]
  wait_for_calls 1
  : >"$STUB_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/sub"

  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    run env PATH="$STUB_DIR:$BARE_PATH" "$sh" -c '. "$1"; unset NDCE_STUB_OK; cd "$2" && echo "$PWD $NDCE_STUB_OK"' _ "$ENV_FILE" "$BATS_TEST_TMPDIR/sub"
    [ "$status" -eq 0 ]
    [[ $output == *"/sub 1" ]]
    run env PATH="$STUB_DIR:$BARE_PATH" "$sh" -c '. "$1"; cd /nonexistent-dir' _ "$ENV_FILE"
    [ "$status" -ne 0 ]
  done
}

@test "command absent from PATH: exit 0, one stderr line, env file untouched" {
  PATH="$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]

  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"nix-devshell-cached-exports"* ]]
  [[ "${lines[0]}" == *"nix profile install github:nhooey/nix-devshell-cached-exports"* ]]

  [ ! -e "$ENV_FILE" ]
}

@test "CLAUDE_ENV_FILE unset: exit 0 silently" {
  PATH="$STUB_DIR:$BARE_PATH" run env -u CLAUDE_ENV_FILE "$HOOK"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
  [ ! -e "$ENV_FILE" ]
}

# Claude Code fetches a plugin again only when its version changes, so a
# hook change without a bump never reaches anyone who already installed it.
# scripts/bump-plugin-version explains this and sets both versions.
NEEDS_BUMP="run scripts/bump-plugin-version (see its header for why)"

@test "plugin.json and marketplace.json give the plugin the same version" {
  v=$(grep -oE '"version": *"[^"]*"' "$REPO_ROOT/.claude-plugin/plugin.json")
  [ -n "$v" ]
  grep -qF -- "$v" "$REPO_ROOT/.claude-plugin/marketplace.json" || {
    echo "marketplace.json lacks $v from plugin.json; $NEEDS_BUMP"
    return 1
  }
}

# .claude-plugin/hooks.sha256 holds the version and hooks/ hash that
# bump-plugin-version last wrote, so a hooks/ change without a bump shows as
# a hash mismatch. `nix flake check` patches the hooks' shebangs, so it sets
# NDCE_TEST_HOOKS_SOURCE to the hooks/ it was given.
@test "every hook change comes with a plugin version bump" {
  read -r version hash <"$REPO_ROOT/.claude-plugin/hooks.sha256"
  grep -qE "\"version\": *\"$version\"" "$REPO_ROOT/.claude-plugin/plugin.json" || {
    echo ".claude-plugin/hooks.sha256 has version $version, not plugin.json's; $NEEDS_BUMP"
    return 1
  }
  current=$("$REPO_ROOT/scripts/bump-plugin-version" --print-hooks-hash "${NDCE_TEST_HOOKS_SOURCE:-$REPO_ROOT/hooks}")
  [ "$hash" = "$current" ] || {
    echo "hooks/ changed since plugin version $version but the version is unchanged; $NEEDS_BUMP"
    return 1
  }
}

@test "bump-plugin-version sets both versions and records the hooks/ hash" {
  cp -R "$REPO_ROOT/.claude-plugin" "$REPO_ROOT/hooks" "$REPO_ROOT/scripts" "$BATS_TEST_TMPDIR/"
  echo '# changed' >>"$BATS_TEST_TMPDIR/hooks/session-start.sh"
  run "$BATS_TEST_TMPDIR/scripts/bump-plugin-version" 7.8.9
  [ "$status" -eq 0 ]
  grep -qF '"version": "7.8.9"' "$BATS_TEST_TMPDIR/.claude-plugin/plugin.json"
  grep -qF '"version": "7.8.9"' "$BATS_TEST_TMPDIR/.claude-plugin/marketplace.json"
  hash=$("$BATS_TEST_TMPDIR/scripts/bump-plugin-version" --print-hooks-hash)
  [ "$hash" != "$("$REPO_ROOT/scripts/bump-plugin-version" --print-hooks-hash)" ]
  [ "$(cat "$BATS_TEST_TMPDIR/.claude-plugin/hooks.sha256")" = "7.8.9 $hash" ]
  run "$BATS_TEST_TMPDIR/scripts/bump-plugin-version" 1.x.2
  [ "$status" -eq 2 ]
}
