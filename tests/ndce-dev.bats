#!/usr/bin/env bats
# Argument parsing for scripts/ndce-dev. Every command runs under --dry-run,
# which prints what would run instead of running it, so nothing here needs
# nix, bats suites or shellcheck.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT=$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)
  DEV=$REPO_ROOT/scripts/ndce-dev
}

@test "--help and help list every command" {
  for args in --help -h help; do
    run "$DEV" "$args"
    [ "$status" -eq 0 ]
    for cmd in lint fmt test e2e check bump-plugin-version help; do
      [[ $output == *"  $cmd"* ]]
    done
  done
}

@test "every command has its own --help" {
  for cmd in lint fmt test e2e check bump-plugin-version help; do
    run "$DEV" "$cmd" --help
    [ "$status" -eq 0 ]
    [[ $output == "usage: ndce-dev $cmd"* ]]
    run "$DEV" help "$cmd"
    [ "$status" -eq 0 ]
    [[ $output == "usage: ndce-dev $cmd"* ]]
  done
}

@test "usage errors exit 2 with a line on stderr" {
  for args in "" "bogus" "--bogus test" "help bogus" "lint extra" "bump-plugin-version 1.0.0 2.0.0"; do
    # shellcheck disable=SC2086 # split the argument list on purpose
    run --separate-stderr "$DEV" $args
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ $stderr == "ndce-dev: "* ]]
  done
}

@test "--dry-run prints each command's invocation, from the repository root" {
  cd "$BATS_TEST_TMPDIR"
  run "$DEV" --dry-run test --filter foo
  [ "$output" = "bats tests/unit.bats tests/hooks.bats tests/ndce-dev.bats --filter foo" ]
  run "$DEV" -n e2e
  [ "$output" = "bats tests/e2e.bats" ]
  run "$DEV" -n fmt
  [ "$output" = "nix fmt --" ]
  run "$DEV" -n check -L
  [ "$output" = "nix flake check -L" ]
  run "$DEV" -n bump-plugin-version patch
  [ "$output" = "scripts/bump-plugin-version patch" ]
  run "$DEV" -n lint
  [[ $output == "shellcheck --shell=bash bin/nix-devshell-cached-exports hooks/"*" scripts/ndce-dev "* ]]
}

@test "check names the untracked files that Nix won't see, then runs nix" {
  repo=$BATS_TEST_TMPDIR/repo
  mkdir -p "$repo/scripts" "$BATS_TEST_TMPDIR/bin"
  cp "$DEV" "$repo/scripts/"
  git -C "$repo" init -q
  git -C "$repo" add scripts
  echo ignored >"$repo/.gitignore"
  touch "$repo/new file" "$repo/ignored"
  printf '#!/bin/sh\necho "nix $*"\n' >"$BATS_TEST_TMPDIR/bin/nix"
  chmod +x "$BATS_TEST_TMPDIR/bin/nix"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr "$repo/scripts/ndce-dev" check
  [ "$status" -eq 0 ]
  [ "$output" = "nix flake check" ]
  [[ $stderr == *"untracked files"* ]]
  [[ $stderr == *"  .gitignore"* ]]
  [[ $stderr == *"  new file"* ]]
  [[ $stderr != *"  ignored"* ]]

  git -C "$repo" add .gitignore "new file"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr "$repo/scripts/ndce-dev" check
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "--dry-run quotes arguments so the printed line can be run again" {
  run "$DEV" -n test --filter 'a b'
  [ "$output" = 'bats tests/unit.bats tests/hooks.bats tests/ndce-dev.bats --filter a\ b' ]
}
