# nix-devshell-cached-exports

`nix-devshell-cached-exports` prints the environment a Nix devshell adds, as
plain `export` statements, from a cache keyed on the files that define the
devshell:

```console
$ cd ~/src/project && nix-devshell-cached-exports
# nix-devshell-cached-exports v1 root=/home/user/src/project key=8c1e0f3b9a…
export CC='clang'
export FOO='multi
line '\''q'\'' $x'
export IN_NIX_SHELL='impure'
export PROJECT_ROOT='/home/user/src/project'
…
__ndce_a='/nix/store/…-hello-2.12.3/bin:/nix/store/…-clang-wrapper-21.1.8/bin:…'
…
export PATH="${__ndce_a}${__ndce_r}"
export __NDCE_ADDED_PATH="${__ndce_a}"
…
```

Every value is single-quoted. `PATH` and `XDG_DATA_DIRS` are not absolute:
the devshell's entries go in front of the caller's own, and sourcing the
output twice, or after another project's, leaves no duplicates. The output
sources in bash 3.2, zsh and POSIX `sh`, and leaves no helper variables
behind.

A caller loads that with `eval "$(nix-devshell-cached-exports)"`. The first
call for a given set of devshell-defining files runs the real entry command
once (`nix develop` or `nix-shell`), including its shell hooks, and caches the
diff; every call after that is a `cat` of a few kilobytes, about 25–30 ms,
against 1–6 s for `nix develop --command …`, depending on the project. Loading is a `source`, not a
re-entry: shell hooks run once per change to the devshell, not once per load.

It hooks nothing into anyone's shell, needs no per-directory allow step, and
re-runs no shell hooks on a load. That is the difference from direnv with
nix-direnv, which re-sources the devshell, hooks included, in every fresh
shell, and which the name is meant to be read against.

## Adapters

### Claude Code plugin

This repository is both a marketplace and a plugin. From inside a session:

```
/plugin marketplace add nhooey/nix-devshell-cached-exports
/plugin install nix-devshell-cached-exports@nix-devshell-cached-exports
```

Its `SessionStart` hook appends
`command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports --max-wait 10 </dev/null)"` to
`$CLAUDE_ENV_FILE`, the file Claude Code prepends to every Bash tool command,
and starts the command in the background to warm the cache, so a first
capture overlaps session start-up instead of delaying it. A Bash command that
arrives while a capture is running waits for it at most 10 seconds, then runs
with the last good environment (or none, before the first capture) and one
line on stderr saying so; the next command after the capture finishes gets
the new environment. If
`nix-devshell-cached-exports` is not on `PATH`, the hook prints one line to
stderr saying so and how to install it, and otherwise does nothing; the
session still starts normally. The plugin refers to the command by name
only — no store paths, no vendored copy, no `nix run`.

### `.envrc`

```bash
watch_file flake.nix flake.lock shell.nix default.nix
eval "$(nix-devshell-cached-exports)"
```

The `eval` is the whole adapter. `watch_file` only tells the shell to
re-evaluate `.envrc` when the devshell's files change; the cache decides
for itself whether that needs a new capture.

### `BASH_ENV`

For anything else — a non-interactive shell that isn't a devshell and isn't
Claude Code — point `BASH_ENV` at a file with the same `eval`, guarded
against re-entry, since `BASH_ENV` is sourced by every non-interactive bash,
including the devshell's own wrapper scripts:

```bash
if [ -z "${NDCE_LOADED:-}" ]; then
  export NDCE_LOADED=1
  eval "$(nix-devshell-cached-exports)"
fi
```

## Install

- `nix profile install github:nhooey/nix-devshell-cached-exports`
- `nix run github:nhooey/nix-devshell-cached-exports`
- From a NixOS, nix-darwin, or home-manager configuration, add
  `inputs.nix-devshell-cached-exports.packages.${system}.default` to your
  system packages or `home.packages`.

## CLI and behaviour

```
nix-devshell-cached-exports [export] [--dir PATH] [--refresh | --max-wait SECONDS] [--format bash]
nix-devshell-cached-exports --print-key [--dir PATH]
nix-devshell-cached-exports --print-cache-path [--dir PATH]
nix-devshell-cached-exports -h | --help
```

- `export` is the default subcommand and may be omitted.
- `--dir PATH` acts as if called from `PATH` (default `$PWD`).
- `--refresh` ignores any cached entry and failure marker for the current
  key and captures again.
- `--max-wait SECONDS`, on a cache miss, runs the capture in a detached copy
  of the command and waits at most `SECONDS` for it. If it is still running
  by then, the command prints the last good environment (or nothing) with
  one line on stderr and exits 0; the capture carries on and the next call
  picks it up. Without it, a call waits for a running capture for up to 15
  minutes. It cannot be combined with `--refresh`.
- `--format bash` is the only accepted format today; `fish`/`json` exit 2
  with "not supported yet".
- `--print-key` prints the cache key and exits; `--print-cache-path` prints
  the cache file's path. Neither captures anything.
- Outside any Nix project (no `flake.nix`, `shell.nix`, or `default.nix`
  found walking up from the directory), it prints nothing and exits 0, so
  it is safe to call unconditionally.

### Cache

```
${XDG_CACHE_HOME:-$HOME/.cache}/nix-devshell-cached-exports/<rootid>/
  <key>.sh        # a good capture (the exact text printed)
  <key>.failed    # failure marker: tail of nix's stderr
  <hash>.v1.deps  # other files the .nix files with this hash depend on
  last-good       # symlink -> <key>.sh of the most recent good capture
  .lock           # flock target
```

`<rootid>` is the first 16 hex characters of the sha256 of the project
root's absolute path, so a git worktree gets its own cache directory even
though it shares the main checkout's history. `<key>` is the first 32 hex
characters of a sha256 over a format-version tag, the project kind, the
sorted names, and the sha256 of each file that defines the devshell (`flake.nix`,
`flake.lock`, every tracked `*.nix`, and any path-input sub-flake's
`flake.lock`). A `shell.nix` or `default.nix` project also counts untracked
`*.nix` files, which nix-shell reads and a flake cannot. Editing any of those
files produces a new key and a fresh capture on the next call.

When those files change, a rough scan of the `*.nix` files finds what else
the devshell may read, records it in `<hash>.v1.deps`, and folds it into the
key:

- a file named by a relative path literal, such as
  `builtins.readFile ./scripts/setup.sh`, resolved from the `.nix` file's
  own directory;
- a known lock file (`Cargo.lock`, `package-lock.json`, `yarn.lock`,
  `pnpm-lock.yaml`, `poetry.lock`, `uv.lock`, `go.sum`, `gomod2nix.toml`,
  `Gemfile.lock`, `mix.lock`, `deps-lock.json`, …) beside a `.nix` file that
  names it, or directly in a directory a path literal names (as `src = ./.;`
  names the project root). Lock files further down, which mostly belong to
  examples and tests, are left out;
- for a `shell.nix` or `default.nix` that looks up `<...>` paths, `NIX_PATH`
  and the targets of the channel profiles, so a channel update recaptures.

The scan errs towards including too much: an extra file only costs a capture
when it changes. A cache hit never scans: it reads `<hash>.v1.deps`, which is
empty for most projects, and hashes the files it lists. Dependencies the scan
cannot see, such as an unpinned `fetchTarball` or a path built from strings,
still need `--refresh`.

Each successful capture also deletes the project's cache files that have not
been written for 30 days, other than the new entry, `last-good` and `.lock`:
entries for old versions of the `.nix` files, their records and failure
markers, and temp files a killed call left behind. A cache hit does not
refresh an entry's age, so an old entry still in use, such as another
branch's, is pruned and costs one capture the next time. Directories of
projects that no longer exist are left in place; delete them by hand.

### Failure fallback

If capturing fails — now, or as remembered by a `<key>.failed` marker from an
earlier attempt — and a last-good entry exists, that last-good entry is
printed with one warning line on stderr:

```
nix-devshell-cached-exports: devshell capture failed for <root>; using the last good environment. Fix it, then run: nix-devshell-cached-exports --refresh
```

With no last-good entry, it prints nothing on stdout, prints the tail of
`nix`'s stderr, and exits 1; later calls with the same key print one line
pointing at the marker instead of the whole tail again. Either way, a
caller's `eval "$(…)"` never sees a half-loaded environment. A failed key is
not retried until a devshell file changes or `--refresh` is given, so a
broken flake costs one capture, not one per command.

The capture runs under `env -i` with only the pass-through variables below,
from the project root, with stdin closed. Anything a shell hook prints to
stdout is discarded, and processes it leaves running do not hold the
capture's lock.

A [numtide/devshell](https://github.com/numtide/devshell) installs a
launcher named after the devshell in its `bin`. If that name is also a
command on the caller's `PATH`, the launcher shadows it, and running the
command in the project starts an interactive devshell instead. The capture
then prints a warning naming the shadowed command, and the next call prints
it once more, in case the capture ran in the background. The fix is to give
the devshell (`devshell.name`) a name of its own.

### Overrides

Three environment variables change what the capture passes through or
drops, each space-separated with `*` as a prefix wildcard:

- `NDCE_PASSTHROUGH` overrides the variables let through into the capture's
  baseline environment (default: `HOME USER LOGNAME PATH TERM LANG LC_*
  TZ NIX_PATH NIX_CONFIG NIX_USER_CONF_FILES NIX_SSL_CERT_FILE
  SSL_CERT_FILE NIX_REMOTE SSH_AUTH_SOCK GIT_SSH GIT_SSH_COMMAND XDG_*
  TMPDIR`).
- `NDCE_EXCLUDE` overrides the variables dropped from the diff regardless of
  whether the devshell changed them (default: `TMPDIR TMP TEMP TEMPDIR
  NIX_BUILD_TOP SHLVL PWD OLDPWD _ __CF_USER_TEXT_ENCODING BASH_* BASHOPTS
  SHELLOPTS`, plus `SHELL` when it is `/sbin/nologin` or `/usr/bin/false`).
- `NDCE_PREPEND_VARS` overrides which colon-list variables are emitted as
  prepend-to-caller rather than as an absolute value (default: `PATH
  XDG_DATA_DIRS`).

## Measured

From an earlier prototype that parsed `nix print-dev-env` output directly,
kept here for reference (Apple Silicon, one numtide/devshell flake project):

| Load | Time |
|---|---:|
| `nix develop --command true` | 3.6 s |
| sourcing `nix print-dev-env` output, startup hooks included | 0.56 s |
| sourcing the same with the startup hook skipped | 0.013 s |
| the prototype, first load after a flake change | 0.7–1.1 s |
| the prototype, cached, from the root, a subdirectory or a worktree | 0.032–0.037 s |

This tool, measured with `hyperfine` on 2026-09-26 (Apple Silicon, Nix
2.34.7, this repository's own numtide/devshell flake, whose startup hook
installs skills; load average 9–14 while measuring, so treat the spread as
noise). Cached rows are a whole `bash -c 'eval "$(nix-devshell-cached-exports)"'`,
bash start-up included:

| Load | Time |
|---|---:|
| `nix develop --command true` (warm evaluation cache) | 1.08 s |
| `nix-devshell-cached-exports`, first capture after a flake change | 1.07–1.66 s |
| `nix-devshell-cached-exports`, cached, from the root | 0.031 s |
| `nix-devshell-cached-exports`, cached, from a subdirectory | 0.023 s |
| `nix-devshell-cached-exports`, cached, from a worktree | 0.026 s |
| computing the cache key alone (`--print-key`) | 0.026 s |

A first capture costs about one `nix develop` plus the diff; every later load
is the cost of a `cat` and an `eval` of a few kilobytes (3 KB here).

## Claude Code plugin verification

Checked against Claude Code 2.1.282 on 2026-09-26, from a headless run with
`claude --plugin-dir <this repo>`:

- A plugin's `SessionStart` hook does receive `CLAUDE_ENV_FILE`, pointing at
  a real file under `~/.claude/session-env/<session-id>/`. This contradicts
  an earlier report that plugin hooks did not receive it
  (github.com/anthropics/claude-code/issues/11649); it may have been fixed
  since, or was specific to a different hook path.
- A throwaway plugin's `SessionStart` hook wrote
  `export NDCE_SPIKE="$(date +%s%N)"` to `$CLAUDE_ENV_FILE`. Two Bash tool
  calls in the same session, each running `echo SPIKE=$NDCE_SPIKE`, printed
  two different non-empty values, confirming the file is re-evaluated on
  every Bash command, not just loaded once at session start.
- `claude plugin validate --strict` against this repository's
  `.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json`
  reports `Validation passed`.
- With a stub `nix-devshell-cached-exports` on `PATH` (printing
  `export NDCE_PLUGIN_OK=1`), a headless session run as
  `claude --plugin-dir <this repo> --model haiku --allowedTools Bash -p "..."`
  from a fixture flake directory ran a Bash command that echoed
  `NDCE_PLUGIN_OK=1`, with nothing in the prompt naming that variable —
  confirming the hook's `eval` line loads into Bash tool commands.
- With the real packaged command on `PATH`, a headless session
  (`claude --plugin-dir <this repo> --model haiku -p …`) started in a flake
  project whose `shellHook` appends a line to a marker file and exports
  `PROBE_PWD="$PWD"`:
  1. The first Bash command already had the devshell: `IN_NIX_SHELL=impure`,
     `PROBE_PWD` set to the project root, the devshell's `hello` on `PATH`.
     The marker had one line: the hook ran once, in the background warm-up.
  2. The session then edited `flake.nix` to add `NDCE_X = "2"` and staged
     it. The next Bash command printed `NDCE_X=2`, with no restart, and
     the marker had two lines: one capture per change, none per command.
  3. A subagent started with the Agent tool ran `echo $NDCE_X $PROBE_PWD`
     and printed `2` and the project root: subagents load the same file.
- The same run, repeated on 2026-09-27 against the published repository —
  the package from `nix build github:nhooey/nix-devshell-cached-exports`
  on `PATH`, and the plugin installed with
  `claude plugin marketplace add nhooey/nix-devshell-cached-exports` and
  `claude plugin install nix-devshell-cached-exports@nix-devshell-cached-exports`
  instead of `--plugin-dir` — gave the same three results.
- With no such command on `PATH`, the same kind of session still completed
  normally (exit 0); the hook itself, exercised directly, printed exactly
  one line to stderr and left `$CLAUDE_ENV_FILE` untouched, matching
  `tests/hooks.bats`.

## Development

- `nix flake check` runs shellcheck, treefmt, the package build and the
  sandbox-safe suites (`tests/unit.bats`, `tests/hooks.bats`, with `nix` and
  `nix-shell` stubbed).
- `nix develop -c test-e2e` runs `tests/e2e.bats` against real nix; each
  capture takes seconds, so it is not part of `nix flake check`.

## Licence

MIT. See `LICENSE`.
