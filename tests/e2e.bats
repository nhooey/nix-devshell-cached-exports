#!/usr/bin/env bats
# End-to-end suite for nix-devshell-cached-exports, against REAL nix (no
# stubs). Covers the same key scenarios as tests/unit.bats, run for real to
# catch anything the stubbed sandbox suite can't (real nix stderr, real
# flake.lock writes, real shellHooks). Skips cleanly if `nix` isn't
# installed. Each capture is ~5s, so this file keeps the capture count low:
# see the comment on each @test.
#
# Fixtures ship with a real flake.nix/shell.nix containing the placeholder
# `@NIXPKGS_URL@`/`@NIXPKGS_REV@`, substituted here with the exact nixpkgs
# revision this repo's own flake.lock is pinned to (read with `nix eval`, no
# jq/python), so no extra input is fetched beyond what's already pinned.

bats_require_minimum_version 1.5.0

setup_file() {
  if ! command -v nix >/dev/null 2>&1; then
    skip "nix not installed; skipping e2e suite"
  fi

  local repo
  repo=$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)

  local rev
  rev=$(
    nix eval --raw --impure --expr \
      "(builtins.fromJSON (builtins.readFile $repo/flake.lock)).nodes.nixpkgs.locked.rev" \
      2>"$BATS_FILE_TMPDIR/nix-eval.err"
  ) || skip "could not read nixpkgs rev from flake.lock via nix eval: $(cat "$BATS_FILE_TMPDIR/nix-eval.err")"

  echo "$rev" >"$BATS_FILE_TMPDIR/nixpkgs-rev"
}

setup() {
  repo=$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)
  fixtures=$repo/tests/fixtures
  ndce_bin=${NDCE_BIN:-$repo/bin/nix-devshell-cached-exports}

  home=$BATS_TEST_TMPDIR/home
  mkdir -p "$home"
  export HOME=$home
  export XDG_CACHE_HOME=$BATS_TEST_TMPDIR/cache
  mkdir -p "$XDG_CACHE_HOME"

  # Sandboxing HOME above also hides this machine's real
  # ~/.config/nix/nix.conf, which is where flakes/nix-command are usually
  # enabled outside NixOS. NIX_CONFIG is in NDCE_PASSTHROUGH's default list,
  # so this reaches the command's own `nix develop`/`nix-shell` calls too.
  export NIX_CONFIG="experimental-features = nix-command flakes"

  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

  unset TMPDIR TMP TEMP TEMPDIR
}

ndce() {
  bash "$ndce_bin" "$@"
}

# Copies fixture $1 into $BATS_TEST_TMPDIR/proj (or $2, if given),
# substitutes the real nixpkgs revision for the @NIXPKGS_URL@/@NIXPKGS_REV@
# placeholders, and commits it with a local git identity. Sets $proj to the
# (symlink-resolved) result.
load_fixture() {
  local name=$1 dest=${2:-$BATS_TEST_TMPDIR/proj}
  local nixpkgs_rev
  nixpkgs_rev=$(cat "$BATS_FILE_TMPDIR/nixpkgs-rev")

  mkdir -p "$dest"
  cp -R "$fixtures/$name/." "$dest/"

  if [ -f "$dest/flake.nix" ]; then
    sed -i.bak "s|@NIXPKGS_URL@|github:NixOS/nixpkgs/$nixpkgs_rev|g" "$dest/flake.nix"
    rm -f "$dest/flake.nix.bak"
  fi
  if [ -f "$dest/shell.nix" ]; then
    sed -i.bak "s|@NIXPKGS_REV@|$nixpkgs_rev|g" "$dest/shell.nix"
    rm -f "$dest/shell.nix.bak"
  fi

  (cd "$dest" && git init -q -b main && git add -A && git commit -q -m init)
  proj=$(cd -P "$dest" && pwd)
}

@test "[e2e] marker written once per change" {
  load_fixture flake-hook
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$proj/marker" | tr -d ' ')" -eq 1 ]

  run ndce
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$proj/marker" | tr -d ' ')" -eq 1 ]

  echo "# a no-op comment" >>"$proj/flake.nix"
  git -C "$proj" add -A && git -C "$proj" commit -q -m edit

  run ndce
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$proj/marker" | tr -d ' ')" -eq 2 ]
}

@test "[e2e] git worktree gets its own root, cache dir, and \$PWD-derived value" {
  load_fixture flake-hook
  cd "$proj"

  run ndce --print-cache-path
  [ "$status" -eq 0 ]
  main_cache_path=$output

  wt=$BATS_TEST_TMPDIR/worktree
  git -C "$proj" worktree add -q "$wt" -b wt-branch
  wt=$(cd -P "$wt" && pwd)
  cd "$wt"

  run ndce --print-cache-path
  [ "$status" -eq 0 ]
  [ "$main_cache_path" != "$output" ]

  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [ "$FIXTURE_HOOK_PWD" = "$wt" ]
}

@test "[e2e] TMPDIR TMP TEMP TEMPDIR survive eval unchanged" {
  load_fixture flake-minimal
  cd "$proj"

  export TMPDIR=$BATS_TEST_TMPDIR/orig-tmpdir
  export TMP=$BATS_TEST_TMPDIR/orig-tmp
  export TEMP=$BATS_TEST_TMPDIR/orig-temp
  export TEMPDIR=$BATS_TEST_TMPDIR/orig-tempdir
  mkdir -p "$TMPDIR" "$TMP" "$TEMP" "$TEMPDIR"

  run ndce
  [ "$status" -eq 0 ]
  eval "$output"

  [ "$TMPDIR" = "$BATS_TEST_TMPDIR/orig-tmpdir" ]
  [ "$TMP" = "$BATS_TEST_TMPDIR/orig-tmp" ]
  [ "$TEMP" = "$BATS_TEST_TMPDIR/orig-temp" ]
  [ "$TEMPDIR" = "$BATS_TEST_TMPDIR/orig-tempdir" ]
}

@test "[e2e] sourcing the output twice leaves PATH/XDG_DATA_DIRS without duplicates" {
  load_fixture flake-path
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  out=$BATS_TEST_TMPDIR/out.sh
  printf '%s\n' "$output" >"$out"

  verify_no_dup_prepend() {
    "$1" -u -c '
      export PATH="/orig/bin:$PATH"
      export XDG_DATA_DIRS="/orig/share"
      . "$1"
      . "$1"
      case "$PATH" in
        /fixture/bin-added:*) : ;;
        *) exit 1 ;;
      esac
      case "$XDG_DATA_DIRS" in
        /fixture/share-added:*) : ;;
        *) exit 1 ;;
      esac
      [ "$(printf %s "$PATH" | tr ":" "\n" | grep -xc "/fixture/bin-added")" -eq 1 ] || exit 1
      [ "$(printf %s "$XDG_DATA_DIRS" | tr ":" "\n" | grep -xc "/fixture/share-added")" -eq 1 ] || exit 1
    ' _ "$out"
  }

  bash_bin=/bin/bash
  [ -x "$bash_bin" ] || bash_bin=bash
  run verify_no_dup_prepend "$bash_bin"
  [ "$status" -eq 0 ]

  if command -v zsh >/dev/null 2>&1; then
    run verify_no_dup_prepend zsh
    [ "$status" -eq 0 ]
  fi
}

@test "[e2e] broken flake falls back to the last good capture, with a warning" {
  load_fixture flake-minimal
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  good_output=$output

  echo 'this is not valid nix syntax {{{' >>"$proj/flake.nix"
  git -C "$proj" add -A && git -C "$proj" commit -q -m break

  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [ "$output" = "$good_output" ]
  [[ "$stderr" == "nix-devshell-cached-exports: devshell capture failed for $proj;"* ]]
}

@test "[e2e] outside any project: exit 0, empty stdout and stderr" {
  outside=$BATS_TEST_TMPDIR/outside
  mkdir -p "$outside"
  cd "$outside"

  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "[e2e] shell.nix fixture works with real nix-shell" {
  load_fixture shell-nix
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [ "$FIXTURE_SHELL_NIX" = "1" ]
}
