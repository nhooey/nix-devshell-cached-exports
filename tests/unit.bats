#!/usr/bin/env bats
# Sandbox-safe unit suite for nix-devshell-cached-exports.
#
# `nix` and `nix-shell` are stubs (tests/stubs), put first on PATH, so this
# suite has no network access and never runs real nix. See CONTRACT.md,
# "Test stubs", for exactly what they do, and tests/e2e.bats for the same
# scenarios against real nix.
#
# Each test copies a fixture from tests/fixtures/ into a fresh tmpdir,
# `git init`s and commits it with a local identity (the command's cache key
# is computed from `git ls-files`), and points HOME/XDG_CACHE_HOME at the
# tmpdir so nothing touches the real machine.

bats_require_minimum_version 1.5.0

setup() {
  repo=$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)
  stubs=$repo/tests/stubs
  fixtures=$repo/tests/fixtures
  ndce_bin=${NDCE_BIN:-$repo/bin/nix-devshell-cached-exports}

  export PATH="$stubs:$PATH"

  home=$BATS_TEST_TMPDIR/home
  mkdir -p "$home"
  export HOME=$home
  export XDG_CACHE_HOME=$BATS_TEST_TMPDIR/cache
  mkdir -p "$XDG_CACHE_HOME"

  export STUB_NIX_LOG=$BATS_TEST_TMPDIR/stub-nix.log
  : >"$STUB_NIX_LOG"
  unset STUB_NIX_SLEEP

  # The command's capture runs under `env -i` with only NDCE_PASSTHROUGH (or
  # its CONTRACT.md default) surviving into it, so STUB_NIX_LOG/STUB_NIX_SLEEP
  # would otherwise never reach the stub. Override with the documented
  # default plus those 2, rather than relying on the (test-only) names
  # happening to match an existing prefix like XDG_*.
  export NDCE_PASSTHROUGH="HOME USER LOGNAME PATH TERM LANG LC_* TZ NIX_PATH NIX_CONFIG NIX_USER_CONF_FILES NIX_SSL_CERT_FILE SSL_CERT_FILE NIX_REMOTE SSH_AUTH_SOCK GIT_SSH GIT_SSH_COMMAND XDG_* TMPDIR STUB_NIX_LOG STUB_NIX_SLEEP"

  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

  unset TMPDIR TMP TEMP TEMPDIR
  # A load in the shell running the tests (this repo's own devshell, say)
  # would make the first load here take its environment back out.
  unset "${!__NDCE_@}"
}

ndce() {
  bash "$ndce_bin" "$@"
}

# Copies fixture $1 into $BATS_TEST_TMPDIR/proj (or $2, if given), commits it
# with a local git identity, and sets $proj to the (symlink-resolved) result.
load_fixture() {
  local name=$1 dest=${2:-$BATS_TEST_TMPDIR/proj}
  mkdir -p "$dest"
  cp -R "$fixtures/$name/." "$dest/"
  (cd "$dest" && git init -q -b main && git add -A && git commit -q -m init)
  proj=$(cd -P "$dest" && pwd)
}

nix_log_lines() {
  wc -l <"$STUB_NIX_LOG" | tr -d ' '
}

@test "flake fixture: exports printed, exit 0, eval sets the variable" {
  load_fixture flake-minimal
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  [[ "$output" == *"export "* ]]

  eval "$output"
  [ "$FIXTURE_MINIMAL" = "1" ]
}

@test "shell.nix fixture works: nix-shell stub invoked, not nix" {
  load_fixture shell-nix
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]

  eval "$output"
  [ "$FIXTURE_SHELL_NIX" = "1" ]

  grep -q '^nix-shell ' "$STUB_NIX_LOG"
  ! grep -q '^nix ' "$STUB_NIX_LOG"
}

@test "marker written once per change; STUB_NIX_LOG counts captures" {
  load_fixture flake-hook
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$proj/marker" | tr -d ' ')" -eq 1 ]
  [ "$(nix_log_lines)" -eq 1 ]

  run ndce
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$proj/marker" | tr -d ' ')" -eq 1 ]
  [ "$(nix_log_lines)" -eq 1 ]

  echo "# a no-op comment" >>"$proj/flake.nix"
  (cd "$proj" && git add -A && git commit -q -m edit)

  run ndce
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$proj/marker" | tr -d ' ')" -eq 2 ]
  [ "$(nix_log_lines)" -eq 2 ]
}

@test "a subdirectory of the root hits the same cache entry" {
  load_fixture flake-minimal
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 1 ]

  mkdir -p "$proj/sub/dir"
  cd "$proj/sub/dir"
  run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 1 ]
}

@test "a git worktree gets its own root, cache dir, and \$PWD-derived value" {
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
  wt_cache_path=$output
  [ "$main_cache_path" != "$wt_cache_path" ]

  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [ "$FIXTURE_HOOK_PWD" = "$wt" ]
}

@test "TMPDIR TMP TEMP TEMPDIR survive eval unchanged" {
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

@test "sourcing the output twice leaves PATH/XDG_DATA_DIRS without duplicates, devshell entries first" {
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

@test "values with newline, quotes, dollar, backslash, spaces round-trip exactly" {
  load_fixture flake-minimal
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  eval "$output"

  expected=$'line one\nline "two" with '\''single'\'' quotes, a $DOLLAR, a \\backslash, and spaces'
  [ "$FIXTURE_TRICKY" = "$expected" ]
}

@test "broken project, no prior entry: empty stdout, nonzero exit, .failed marker, no .sh" {
  load_fixture flake-minimal
  cd "$proj"
  touch BROKEN
  git add -A && git commit -q -m broken

  run ndce --print-cache-path
  [ "$status" -eq 0 ]
  cache_dir=$(dirname -- "$output")

  run --separate-stderr ndce
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ -n "$stderr" ]

  shopt -s nullglob
  sh_entries=("$cache_dir"/*.sh)
  failed_entries=("$cache_dir"/*.failed)
  shopt -u nullglob
  [ "${#sh_entries[@]}" -eq 0 ]
  [ "${#failed_entries[@]}" -eq 1 ]
}

@test "broken after a good capture: stale fallback, negative cache, --refresh recaptures" {
  load_fixture flake-minimal
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  good_output=$output
  [ "$(nix_log_lines)" -eq 1 ]

  # BROKEN alone doesn't change the cache key, so it would never be noticed
  # while the old key is still a cache hit; pair it with a .nix edit so the
  # next call computes a new key, misses the cache, and actually attempts
  # (and fails) a capture.
  touch BROKEN
  echo "# now broken" >>flake.nix
  git add -A && git commit -q -m broken

  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [ "$output" = "$good_output" ]
  [ "$stderr" = "nix-devshell-cached-exports: devshell capture failed for $proj; using the last good environment. Fix it, then run: nix-devshell-cached-exports --refresh" ]
  [ "$(nix_log_lines)" -eq 2 ]

  # Negative cache: a 2nd broken call must not invoke the stub again.
  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [ "$output" = "$good_output" ]
  [ "$(nix_log_lines)" -eq 2 ]

  # --refresh forces another capture attempt despite the failure marker.
  run --separate-stderr ndce --refresh
  [ "$status" -eq 0 ]
  [ "$output" = "$good_output" ]
  [ "$(nix_log_lines)" -eq 3 ]
}

@test "outside any project: exit 0, empty stdout and stderr, every mode" {
  outside=$BATS_TEST_TMPDIR/outside
  mkdir -p "$outside"
  cd "$outside"

  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr ndce --print-key
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr ndce --print-cache-path
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "--print-key is stable and changes after editing a .nix file; --print-cache-path is under XDG_CACHE_HOME" {
  load_fixture flake-minimal
  cd "$proj"

  run ndce --print-key
  [ "$status" -eq 0 ]
  key1=$output
  [ -n "$key1" ]

  run ndce --print-key
  [ "$status" -eq 0 ]
  [ "$output" = "$key1" ]

  run ndce --print-cache-path
  [ "$status" -eq 0 ]
  case "$output" in
    "$XDG_CACHE_HOME"/*) : ;;
    *)
      echo "cache path not under XDG_CACHE_HOME: $output" >&2
      return 1
      ;;
  esac

  echo "# a no-op comment" >>"$proj/flake.nix"
  git add -A && git commit -q -m edit

  run ndce --print-key
  [ "$status" -eq 0 ]
  [ "$output" != "$key1" ]
}

@test "--format fish and an unknown flag both exit 2" {
  load_fixture flake-minimal
  cd "$proj"

  run --separate-stderr ndce --format fish
  [ "$status" -eq 2 ]
  [ -n "$stderr" ]

  run --separate-stderr ndce --bogus-flag
  [ "$status" -eq 2 ]
  [ -n "$stderr" ]
}

@test "concurrency: two simultaneous first loads produce exactly one capture" {
  load_fixture flake-minimal
  cd "$proj"
  export STUB_NIX_SLEEP=0.5

  ndce >"$BATS_TEST_TMPDIR/out1" 2>"$BATS_TEST_TMPDIR/err1" &
  pid1=$!
  ndce >"$BATS_TEST_TMPDIR/out2" 2>"$BATS_TEST_TMPDIR/err2" &
  pid2=$!

  wait "$pid1"
  status1=$?
  wait "$pid2"
  status2=$?

  [ "$status1" -eq 0 ]
  [ "$status2" -eq 0 ]
  diff "$BATS_TEST_TMPDIR/out1" "$BATS_TEST_TMPDIR/out2"
  [ "$(nix_log_lines)" -eq 1 ]
}

@test "timing: cached load, reported not asserted" {
  load_fixture flake-minimal
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]

  iterations=20
  # GNU date (coreutils) for nanoseconds; macOS /bin/date has no %N.
  start_ns=$(date +%s%N)
  for _ in $(seq 1 "$iterations"); do
    eval "$(ndce)"
  done
  end_ns=$(date +%s%N)

  us_per_load=$(((end_ns - start_ns) / iterations / 1000))
  echo "# cached load + eval: ${us_per_load} us/iteration over ${iterations} iterations" >&3
}

# Replaces the loaded fixture's stub-env.sh with $1 and commits it.
set_stub_env() {
  printf '%s\n' "$1" >"$proj/stub-env.sh"
  (cd "$proj" && git add -A && git commit -q -m stub-env)
}

@test "a process the shell hook leaves running does not hold the capture lock" {
  load_fixture flake-minimal
  cd "$proj"
  set_stub_env 'sleep 30 </dev/null >/dev/null 2>&1 3>&- &
echo $! >"$PWD/bg.pid"
export FIXTURE_MINIMAL=1'

  run ndce
  [ "$status" -eq 0 ]

  echo "# edit" >>flake.nix
  git add -A && git commit -q -m edit

  run timeout 10 bash "$ndce_bin"
  kill "$(cat bg.pid)" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "entries the devshell repeats from the caller's PATH are not recorded as added" {
  load_fixture flake-minimal
  cd "$proj"
  set_stub_env 'export PATH="/opt/a/bin:/fake/keep:$PATH"'
  export PATH="$stubs:/fake/keep:$PATH"

  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [ "$__NDCE_ADDED_PATH" = "/opt/a/bin" ]

  # Loading a second project in the same shell keeps the caller's entry.
  load_fixture flake-path "$BATS_TEST_TMPDIR/other"
  cd "$proj"
  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [[ ":$PATH:" == *":/fake/keep:"* ]]
  [[ ":$PATH:" != *":/opt/a/bin:"* ]]
}

@test "text a shell hook prints to stdout does not corrupt the captured environment" {
  load_fixture flake-minimal
  cd "$proj"
  set_stub_env 'export AAA_FIRST=1 ZZZ_LAST=2
echo "GREETING=hello from the hook"
printf ready'

  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [[ "$output" != *hello* ]]
  [[ "$output" != *ready* ]]
  eval "$output"
  [ "$AAA_FIRST" = 1 ]
  [ "$ZZZ_LAST" = 2 ]
}

@test "moving bytes across a file boundary changes the key" {
  load_fixture flake-minimal
  cd "$proj"
  keys=()
  for pair in $'x = 1;\n|y = 2;\n' $'x = 1;|\ny = 2;\n' $'x = 1;\ny| = 2;\n'; do
    printf '%s' "${pair%%|*}" >a.nix
    printf '%s' "${pair#*|}" >b.nix
    git add -A && git commit -q -m "$pair"
    run ndce --print-key
    [ "$status" -eq 0 ]
    keys+=("$output")
  done
  [ "${keys[0]}" != "${keys[1]}" ]
  [ "${keys[1]}" != "${keys[2]}" ]
  [ "${keys[0]}" != "${keys[2]}" ]
}

@test "a remembered failure prints one line, not the details again" {
  load_fixture flake-minimal
  cd "$proj"
  touch BROKEN
  git add -A && git commit -q -m broken

  run --separate-stderr ndce
  [ "$status" -ne 0 ]

  run --separate-stderr ndce
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *--refresh* ]]
}

# Waits up to 10 s for the cache entry of the current key to appear.
wait_for_entry() {
  local path i
  path=$(ndce --print-cache-path)
  for i in $(seq 100); do
    [ -s "$path" ] && return 0
    sleep 0.1
  done
  return 1
}

@test "--max-wait, capture faster than the wait: prints the exports" {
  load_fixture flake-minimal
  cd "$proj"

  run --separate-stderr ndce --max-wait 10
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  eval "$output"
  [ "$FIXTURE_MINIMAL" = "1" ]
}

@test "--max-wait, slow first capture: returns early with nothing, capture finishes in the background" {
  load_fixture flake-minimal
  cd "$proj"
  export STUB_NIX_SLEEP=3

  start=$SECONDS
  run --separate-stderr ndce --max-wait 1
  [ $((SECONDS - start)) -lt 3 ]
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"still capturing"* ]]

  wait_for_entry
  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [ "$FIXTURE_MINIMAL" = "1" ]
  [ "$(nix_log_lines)" -eq 1 ]
}

@test "--max-wait, slow capture after an edit: prints the last good environment" {
  load_fixture flake-minimal
  cd "$proj"

  run ndce
  [ "$status" -eq 0 ]
  good_output=$output

  echo "# edit" >>flake.nix
  git add -A && git commit -q -m edit
  export STUB_NIX_SLEEP=3

  run --separate-stderr ndce --max-wait 1
  [ "$status" -eq 0 ]
  [ "$output" = "$good_output" ]
  [[ "$stderr" == *"using the last good environment"* ]]

  wait_for_entry
  [ "$(nix_log_lines)" -eq 2 ]
}

@test "--max-wait: repeated calls during one capture start no second capture" {
  load_fixture flake-minimal
  cd "$proj"
  export STUB_NIX_SLEEP=2

  run ndce --max-wait 0
  [ "$status" -eq 0 ]
  run ndce --max-wait 0
  [ "$status" -eq 0 ]

  wait_for_entry
  [ "$(nix_log_lines)" -eq 1 ]
}

@test "--max-wait rejects a non-number and --refresh" {
  load_fixture flake-minimal
  cd "$proj"

  run --separate-stderr ndce --max-wait soon
  [ "$status" -eq 2 ]
  run --separate-stderr ndce --max-wait 5 --refresh
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Dependencies outside the .nix files

# Writes a git-initialised project at $proj whose flake.nix holds $1.
make_flake() {
  proj=$BATS_TEST_TMPDIR/proj
  mkdir -p "$proj"
  printf '%s\n' "$1" >"$proj/flake.nix"
  (cd "$proj" && git init -q -b main && git add -A && git commit -q -m init)
  proj=$(cd -P "$proj" && pwd)
  cd "$proj"
}

key() {
  run ndce --print-key
  [ "$status" -eq 0 ]
  printf '%s' "$output"
}

@test "deps: a file a .nix file names by relative path joins the key" {
  make_flake '{ outputs = _: { x = builtins.readFile ./scripts/setup.sh; y = ../outside.txt; }; }'
  mkdir scripts
  echo one >scripts/setup.sh
  echo other >README.md
  k1=$(key)

  echo two >scripts/setup.sh
  k2=$(key)
  [ "$k2" != "$k1" ]

  echo changed >README.md
  [ "$(key)" = "$k2" ]

  # Paths are resolved from the .nix file's own directory.
  mkdir -p nix
  printf '{ a = import ../scripts/setup.sh; }\n' >nix/sub.nix
  git add -A && git commit -q -m sub
  k3=$(key)
  echo three >scripts/setup.sh
  [ "$(key)" != "$k3" ]
}

@test "deps: lock files join the key when named beside a .nix file or in a directory one names" {
  make_flake '{ outputs = _: { }; }'
  mkdir -p rust examples/web
  echo a >Cargo.lock
  echo a >rust/Cargo.lock
  echo a >examples/web/package-lock.json
  git add -A && git commit -q -m locks
  k1=$(key)

  # Not referenced: editing it does not change the key.
  echo b >Cargo.lock
  [ "$(key)" = "$k1" ]

  # Named in a .nix file: the one beside it counts, not a nested one.
  printf '{ outputs = _: { lock = "Cargo.lock"; }; }\n' >flake.nix
  git add -A && git commit -q -m named
  k2=$(key)
  echo b >rust/Cargo.lock
  [ "$(key)" = "$k2" ]
  echo c >Cargo.lock
  [ "$(key)" != "$k2" ]

  # In a directory a path literal names.
  printf '{ outputs = _: { lock = "${./rust}/x"; }; }\n' >flake.nix
  git add -A && git commit -q -m dir
  k3=$(key)
  echo c >rust/Cargo.lock
  [ "$(key)" != "$k3" ]

  # `src = ./.` counts the root's lock files, not nested ones.
  printf '{ outputs = _: { src = ./.; }; }\n' >flake.nix
  git add -A && git commit -q -m src
  k4=$(key)
  echo b >examples/web/package-lock.json
  [ "$(key)" = "$k4" ]
  echo d >Cargo.lock
  [ "$(key)" != "$k4" ]
}

@test "deps: a deleted dependency changes the key" {
  make_flake '{ outputs = _: { x = builtins.readFile ./data.json; }; }'
  echo '{}' >data.json
  k1=$(key)
  rm data.json
  [ "$(key)" != "$k1" ]
}

@test "deps: a shell.nix project counts untracked .nix files; a flake does not" {
  load_fixture shell-nix
  cd "$proj"
  k1=$(key)
  echo '{ }' >extra.nix
  [ "$(key)" != "$k1" ]

  rm extra.nix
  make_flake '{ outputs = _: { }; }'
  k2=$(key)
  echo '{ }' >extra.nix
  [ "$(key)" = "$k2" ]
}

@test "deps: a shell.nix with <...> lookups keys on NIX_PATH; a flake does not" {
  load_fixture shell-nix
  cd "$proj"
  printf '{ pkgs ? import <nixpkgs> { } }: pkgs.mkShellNoCC { }\n' >shell.nix
  git add -A && git commit -q -m angle
  k1=$(NIX_PATH=nixpkgs=/a key)
  [ "$(NIX_PATH=nixpkgs=/a key)" = "$k1" ]
  [ "$(NIX_PATH=nixpkgs=/b key)" != "$k1" ]

  make_flake '{ outputs = _: { x = <nixpkgs>; }; }'
  k2=$(NIX_PATH=nixpkgs=/a key)
  [ "$(NIX_PATH=nixpkgs=/b key)" = "$k2" ]
}

@test "deps: a project with none keeps its key, and records the scan once" {
  load_fixture flake-minimal
  cd "$proj"
  k1=$(key)
  run ndce --print-cache-path
  dir=${output%/*}
  # The key of a project without dependencies is the .nix files' own hash.
  [ -e "$dir/$k1.v3.deps" ]
  [ ! -s "$dir/$k1.v3.deps" ]
}

@test "a devshell launcher named after a command on PATH: warned at capture and once after" {
  load_fixture flake-minimal
  cd "$proj"
  dsd=$BATS_TEST_TMPDIR/devshell-dir
  mkdir -p "$dsd/bin" "$BATS_TEST_TMPDIR/real-bin"
  printf '#!/bin/sh\n' >"$dsd/entrypoint"
  chmod +x "$dsd/entrypoint"
  ln -s ../entrypoint "$dsd/bin/mycmd"
  printf '#!/bin/sh\n' >"$BATS_TEST_TMPDIR/real-bin/mycmd"
  chmod +x "$BATS_TEST_TMPDIR/real-bin/mycmd"
  set_stub_env "export DEVSHELL_DIR=$dsd
export FIXTURE_MINIMAL=1"
  export PATH="$BATS_TEST_TMPDIR/real-bin:$PATH"

  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [[ $stderr == *"launcher shadows $BATS_TEST_TMPDIR/real-bin/mycmd"* ]]

  run --separate-stderr ndce
  [[ $stderr == *"launcher shadows"* ]]

  run --separate-stderr ndce
  [ -z "$stderr" ]
  [[ $output == *FIXTURE_MINIMAL* ]]
}

@test "a devshell launcher with no command of its name on PATH: no warning" {
  load_fixture flake-minimal
  cd "$proj"
  dsd=$BATS_TEST_TMPDIR/devshell-dir
  mkdir -p "$dsd/bin"
  printf '#!/bin/sh\n' >"$dsd/entrypoint"
  ln -s ../entrypoint "$dsd/bin/ndce-test-no-such-command"
  set_stub_env "export DEVSHELL_DIR=$dsd"

  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "a capture prunes this project's cache files untouched for 30 days, and nothing else" {
  load_fixture flake-minimal
  cd "$proj"
  run ndce
  [ "$status" -eq 0 ]
  run ndce --print-cache-path
  cache_file=$output
  dir=${cache_file%/*}
  k=$(key)
  printf 'x' >"$dir/0123456789abcdef0123456789abcdef.sh"
  printf 'x' >"$dir/0123456789abcdef0123456789abcdef.failed"
  printf 'x' >"$dir/.$k.sh.AbCdEf"
  printf 'x' >"$dir/fedcba9876543210fedcba9876543210.sh"
  touch -d '40 days ago' "$dir/0123456789abcdef0123456789abcdef.sh" \
    "$dir/0123456789abcdef0123456789abcdef.failed" "$dir/.$k.sh.AbCdEf" \
    "$dir/$k.sh" "$dir/$k.v3.deps" "$dir/.lock"

  run ndce --refresh
  [ "$status" -eq 0 ]
  [ ! -e "$dir/0123456789abcdef0123456789abcdef.sh" ]
  [ ! -e "$dir/0123456789abcdef0123456789abcdef.failed" ]
  [ ! -e "$dir/.$k.sh.AbCdEf" ]
  [ -e "$dir/fedcba9876543210fedcba9876543210.sh" ]
  [ -e "$dir/$k.v3.deps" ]
  [ -e "$dir/.lock" ]
  [ -s "$cache_file" ]
  [ -L "$dir/last-good" ]
}

# A fake store, with one devshell path in it, for the PATH and GC tests.
fake_store() {
  export NIX_STORE_DIR=$BATS_TEST_TMPDIR/store
  tool=$NIX_STORE_DIR/aaaa-tool
  mkdir -p "$tool/bin"
}

@test "store entries the caller already has (inside the devshell) are still added; the placeholder is not" {
  load_fixture flake-minimal
  cd "$proj"
  fake_store
  set_stub_env "export PATH=\"$tool/bin:/path-not-set:\$PATH\""
  export PATH="$tool/bin:$PATH"

  run ndce
  [ "$status" -eq 0 ]
  [[ $output == *"__ndce_a='$tool/bin'"* ]]
  [[ $output != *path-not-set* ]]
}

@test "an entry whose devshell was garbage-collected is captured again" {
  load_fixture flake-minimal
  cd "$proj"
  fake_store
  set_stub_env "export PATH=\"$tool/bin:\$PATH\""

  run ndce
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == *" store=$tool" ]]
  run ndce
  [ "$(nix_log_lines)" -eq 1 ]

  rm -rf "$tool"
  run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 2 ]
}

@test "a broken flake does not fall back to a last good entry that was garbage-collected" {
  load_fixture flake-minimal
  cd "$proj"
  fake_store
  set_stub_env "export PATH=\"$tool/bin:\$PATH\""
  run ndce
  [ "$status" -eq 0 ]

  rm -rf "$tool"
  touch BROKEN
  echo "# edit" >>flake.nix
  git add -A && git commit -q -m broken
  run ndce
  [ "$status" -eq 1 ]
  [[ $output != *"export "* ]]
}

@test "by default every variable but SHELL is cached, in an owner-only directory" {
  load_fixture flake-minimal
  cd "$proj"
  set_stub_env 'export HF_TOKEN=tok-value SHELL=/bin/devshell-bash'
  run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [[ $output == *"HF_TOKEN='tok-value'"* ]]
  [[ $output != *SHELL=* ]]
  [ -z "$stderr" ]
  run ndce --print-cache-path
  [ "$(stat -c %a "${output%/*}")" = 700 ]
}

@test "NDCE_SECRET_VARS keeps matching variables out of the cache, with a warning" {
  load_fixture flake-minimal
  cd "$proj"
  set_stub_env 'export HF_TOKEN=tok-value MY_Password=pw-value KEEP_ME=1'

  NDCE_SECRET_VARS='*TOKEN* *PASSWORD*' run --separate-stderr ndce
  [ "$status" -eq 0 ]
  [[ $output == *"KEEP_ME"* ]]
  [[ $output != *tok-value* && $output != *pw-value* ]]
  [[ $stderr == *"left out of the cache by NDCE_SECRET_VARS, so not set: HF_TOKEN MY_Password."* ]]
  run ndce --print-cache-path
  ! grep -q -e tok-value -e pw-value "$output"
}

# flake-minimal with a flake.lock, so that a capture may use a copy.
locked_flake() {
  load_fixture flake-minimal
  cd "$proj"
  echo '{}' >flake.lock
  git add -A && git commit -q -m lock
}

@test "source: a flake that reads nothing else is captured from a copy of its files, with a GC root" {
  locked_flake
  run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 1 ]
  grep -q '^nix develop path:' "$STUB_NIX_LOG"
  k=$(key)
  run ndce --print-cache-path
  [ -L "${output%/*}/$k.profile" ]
  # The copy is gone once the capture is done.
  [ -z "$(find "${output%/*}" -name '.src.*')" ]
}

@test "source: a reference to the project's own source still tries the copy first" {
  locked_flake
  sed -i 's|FIXTURE_MINIMAL = "1";|FIXTURE_MINIMAL = "1"; src = inputs.self; other = ./.;|' flake.nix
  git add -A && git commit -q -m self
  run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 1 ]
  grep -q '^nix develop path:' "$STUB_NIX_LOG"
}

@test "source: a devshell that depends on the copy is captured again from the project" {
  locked_flake
  touch REFS_SOURCE
  git add -A && git commit -q -m refs
  run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 2 ]
  grep -q '^nix develop path:' "$STUB_NIX_LOG"
  grep -q "^nix develop $proj " "$STUB_NIX_LOG"
}

@test "source: a path reaching outside the project, or NDCE_FLAKE_SOURCE=tree, uses the project" {
  locked_flake
  mkdir -p ../sibling
  sed -i 's|FIXTURE_MINIMAL = "1";|FIXTURE_MINIMAL = "1"; other = ../sibling;|' flake.nix
  git add -A && git commit -q -m outside
  run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 1 ]
  grep -q "^nix develop $proj " "$STUB_NIX_LOG"

  sed -i 's|other = ../sibling;||' flake.nix
  git add -A && git commit -q -m plain
  : >"$STUB_NIX_LOG"
  NDCE_FLAKE_SOURCE=tree run ndce
  [ "$status" -eq 0 ]
  grep -q "^nix develop $proj " "$STUB_NIX_LOG"

  NDCE_FLAKE_SOURCE=bogus run ndce
  [ "$status" -eq 1 ]
}

@test "source: NDCE_FLAKE_SOURCE=minimal keeps the copy without checking it" {
  locked_flake
  touch REFS_SOURCE
  git add -A && git commit -q -m refs
  NDCE_FLAKE_SOURCE=minimal run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 1 ]
  grep -q '^nix develop path:' "$STUB_NIX_LOG"
}

# Two projects with different devshells, loaded one after the other.
two_projects() {
  load_fixture flake-minimal "$BATS_TEST_TMPDIR/a"
  a=$proj
  set_stub_env 'export ONLY_A=1 SHARED=a PATH="/opt/a/bin:$PATH"'
  load_fixture flake-minimal "$BATS_TEST_TMPDIR/b"
  b=$proj
  set_stub_env 'export SHARED=b'
}

@test "unload: loading another project takes the first one's variables and PATH entries out" {
  two_projects
  export SHARED=caller
  cd "$a"
  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [ "$ONLY_A" = 1 ] && [ "$SHARED" = a ]
  [[ ":$PATH:" == *":/opt/a/bin:"* ]]

  cd "$b"
  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [ -z "${ONLY_A+set}" ]
  [ "$SHARED" = b ]
  [[ ":$PATH:" != *":/opt/a/bin:"* ]]
  [ "$__NDCE_ROOT" = "$b" ]
}

@test "unload: a project that cannot load yet, or no project, leaves none of the last one's environment" {
  two_projects
  cd "$a"
  run ndce
  eval "$output"
  [ "$ONLY_A" = 1 ]
  path_before_a=${PATH#/opt/a/bin:}

  # b is still capturing: nothing of a's may remain.
  cd "$b"
  STUB_NIX_SLEEP=3 run --separate-stderr ndce --max-wait 1
  [ "$status" -eq 0 ]
  [[ $stderr == *"still capturing"* ]]
  eval "$output"
  [ -z "${ONLY_A+set}" ] && [ -z "${IN_NIX_SHELL+set}" ] && [ -z "${__NDCE_ROOT+set}" ]
  [ "$PATH" = "$path_before_a" ]

  # Outside any project, the same.
  cd "$a"
  run ndce
  eval "$output"
  [ "$ONLY_A" = 1 ]
  cd "$BATS_TEST_TMPDIR"
  run ndce
  [ "$status" -eq 0 ]
  eval "$output"
  [ -z "${ONLY_A+set}" ] && [ "$PATH" = "$path_before_a" ]

  # The other modes print only what they are asked for.
  cd "$a"
  run ndce
  eval "$output"
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr ndce --print-key
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "unload: the same project loaded twice keeps its variables" {
  two_projects
  cd "$a"
  run ndce
  eval "$output"
  run ndce
  eval "$output"
  [ "$ONLY_A" = 1 ]
}

@test "source: a copy that fails to evaluate is retried on the project" {
  locked_flake
  touch NEEDS_TREE
  git add -A && git commit -q -m needs-tree
  run ndce
  [ "$status" -eq 0 ]
  [ "$(nix_log_lines)" -eq 2 ]
  grep -q '^nix develop path:' "$STUB_NIX_LOG"
  grep -q "^nix develop $proj " "$STUB_NIX_LOG"
}

@test "source: a lock file the copy's capture updated is written back to the project" {
  locked_flake
  touch LOCK_UPDATE
  git add -A && git commit -q -m lock-update
  run ndce
  [ "$status" -eq 0 ]
  [ "$(cat flake.lock)" = '{"updated": true}' ]
  # Stored under the key of the updated lock file: the next call is a hit.
  run ndce
  [ "$(nix_log_lines)" -eq 1 ]
}
