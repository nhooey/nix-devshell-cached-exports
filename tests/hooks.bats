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

@test "stub on PATH: eval line appended once across two runs, stub invoked for warm-up" {
  PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]

  [ -f "$ENV_FILE" ]
  [ "$(grep -cF -- "$EXPECTED_LINE" "$ENV_FILE")" -eq 1 ]

  wait_for_calls 1
  first_count="$(wc -l <"$STUB_LOG")"

  # Run the hook a second time: the line must not be duplicated.
  PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]

  [ "$(grep -cF -- "$EXPECTED_LINE" "$ENV_FILE")" -eq 1 ]
  [ "$(wc -l <"$ENV_FILE")" -eq 1 ]

  # The stub was invoked again for the second run's warm-up.
  wait_for_calls $((first_count + 1))
}

@test "warm-up runs in the background: the hook does not wait for it" {
  start=$(date +%s)
  NDCE_STUB_SLEEP=3 PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]
  [ $(($(date +%s) - start)) -lt 3 ]
  [ "$(grep -cF -- "$EXPECTED_LINE" "$ENV_FILE")" -eq 1 ]
}

@test "command supports --max-wait: the eval line passes it" {
  NDCE_STUB_HELP='  --max-wait SECONDS  ...' PATH="$STUB_DIR:$BARE_PATH" CLAUDE_ENV_FILE="$ENV_FILE" run "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(cat "$ENV_FILE")" = 'command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports --max-wait 10 </dev/null)"' ]
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
