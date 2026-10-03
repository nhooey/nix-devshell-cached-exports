# nix-devshell-cached-exports

Loading a Nix devshell with `nix develop --command …` costs 1–6 seconds
every time. `nix-devshell-cached-exports` enters the devshell once, records
what it changed in the environment, and prints that as `export` statements
from a cache. Loading it again costs about 25–30 ms:

```console
$ cd ~/src/project && eval "$(nix-devshell-cached-exports)"
```

It comes with a Claude Code plugin that loads the devshell into every Bash
command an agent runs, so agents don't need `nix develop` at all.

- **Shell hooks run once per capture, not once per load.** A new capture
  happens only when a file that defines the devshell changes.
- **No setup per project.** There is no `.envrc` and no allow step, and
  nothing is hooked into anyone's shell.
- **Any Nix project.** It handles flakes (`flake.nix`) and `shell.nix` /
  `default.nix` projects.

That is the difference from direnv with nix-direnv, which re-runs the
devshell's shell hooks in every new shell and needs an `.envrc` per project.

## Install

Install the command first. The plugin calls it by name.

- `nix profile install github:nhooey/nix-devshell-cached-exports`
- Or add `inputs.nix-devshell-cached-exports.packages.${system}.default` to
  your NixOS, nix-darwin or home-manager packages.
- Or try it with `nix run github:nhooey/nix-devshell-cached-exports`.

Then, in Claude Code:

```
/plugin marketplace add nhooey/nix-devshell-cached-exports
/plugin install nix-devshell-cached-exports@nix-devshell-cached-exports
```

and restart Claude Code (`claude --resume` keeps the conversation).

### Updating, and reloading the plugin

The command and the plugin update separately:

- **The command:** `nix profile upgrade nix-devshell-cached-exports`. The
  next Bash command uses it; nothing needs a restart.
- **The plugin:**

  ```
  /plugin marketplace update nix-devshell-cached-exports
  /plugin update nix-devshell-cached-exports@nix-devshell-cached-exports
  ```

  then restart Claude Code.

`/reload-plugins` is not enough on its own. It reloads the copy Claude Code
already has, and the lines the plugin adds to each session are written only
when a session starts. Claude Code also fetches a new copy only when the
plugin's version number changes, so this repository bumps it with every
change to the plugin (see `AGENTS.md`).

To check that a session has the current plugin, run `type cd` in a Bash
command: it should print a shell function, not "shell builtin".

## The Claude Code plugin

### What each session gets

When a session starts, the plugin adds two lines to `$CLAUDE_ENV_FILE`,
which Claude Code runs before every Bash command:

```bash
command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports --max-wait 10 </dev/null)"
cd() { builtin cd "$@" || return; command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports --max-wait 10 </dev/null)"; return 0; }
```

- **The first line** loads the devshell of the directory the command starts
  in.
- **The `cd` function** loads again after changing directory, so
  `cd .worktrees/topic && make` runs `make` with the worktree's devshell.
  Each `cd` costs a cached load, 20–40 ms.
- **Leaving a project** unloads it. Loading another project, or a directory
  outside any project, first removes the variables and `PATH` entries the
  previous project added. A tool from the wrong checkout is then "not
  found" rather than silently running against the wrong files.

The session start also begins the first capture in the background, so it
overlaps with start-up. A Bash command that arrives while a capture is
running waits for it for at most 10 seconds. After that it runs with the
last good environment, or none before the first capture, and prints one
line on stderr saying so. The next command after the capture finishes gets
the new environment.

If the command isn't installed, the plugin prints one line saying how to
install it and otherwise does nothing.

### Subagents

- **Every subagent** loads the same lines, for its own working directory.
- **Context for subagents:** in a Nix project, a `SubagentStart` hook tells
  each subagent that its devshell is already loaded, so it runs tools
  directly instead of through `nix develop --command`. It also tells it
  that a `cd` inside `bash -c` or a script does not reload.
- **A reminder about `nix develop`:** when a Bash command runs
  `nix develop --command` or `nix-shell --run` on the devshell that's
  already loaded, a `PreToolUse` hook adds a reminder that it isn't needed.
  The command still runs, since another flake or devshell output can be a
  good reason.
- **The `nix-devshell-cached-exports:worktree-worker` agent** runs in its own
  git worktree (`isolation: worktree`). Every Bash command it runs starts
  there, so every command, and every process those commands start, has
  that worktree's devshell. Use it for changes made alongside other work.

## Caveats

- **A `cd` in a child process does not reload.** The `cd` function exists
  only in the shell that runs the Bash command. In
  `bash -c 'cd .worktrees/x && render'`, or a script that changes
  directory, the child keeps the parent's environment, `PRJ_ROOT` included,
  and can run one checkout's code against another's files without any
  error. Ways around it:
  - work from the right directory: start the session there, or use
    `EnterWorktree` or the `worktree-worker` agent;
  - make devshell commands find their checkout from where they run
    (`git rev-parse --show-toplevel`) instead of trusting an inherited
    `PRJ_ROOT`.
- **The first load in a new directory waits.** A new worktree has its own
  cache, so the first command or `cd` there waits up to 10 seconds for a
  capture, and the devshell's shell hooks run there.
- **Shell hooks run once per capture.** A hook that must run for every
  command, such as one that fetches a short-lived secret or syncs files,
  does not fit. Neither does timing each command.
- **Session lines are written only at session start.** Installing, enabling
  or updating the plugin takes a restart to reach a session.
- **The command and the plugin are installed separately**, and nothing
  checks that their versions match.
- **Unloading is partial.** It removes the variables a project added and the
  entries it put in front of `PATH` and `XDG_DATA_DIRS`. A variable the
  caller already had before the load is not restored to its old value.
- **Some dependencies are invisible.** An unpinned `fetchTarball`, or a path
  built from strings, does not change the cache key. Run
  `nix-devshell-cached-exports --refresh` after changing what it points at.
- **Secrets are cached by default.** See
  [Secrets](#store-copies-gc-roots-and-secrets).
- **The `nix develop` reminder matches command text.** It misses commands
  with options between `nix develop` and `--command`, and anything inside a
  script.

## Other ways to load it

### `.envrc`

```bash
watch_file flake.nix flake.lock shell.nix default.nix
eval "$(nix-devshell-cached-exports)"
```

`watch_file` only tells direnv when to run `.envrc` again; the cache
decides whether that needs a new capture.

### `BASH_ENV`

For other non-interactive bash shells, point `BASH_ENV` at a file with the
same `eval`. Guard it, since every non-interactive bash reads `BASH_ENV`,
including the devshell's own wrapper scripts:

```bash
if [ -z "${NDCE_LOADED:-}" ]; then
  export NDCE_LOADED=1
  eval "$(nix-devshell-cached-exports)"
fi
```

## Command reference

```
nix-devshell-cached-exports [export] [--dir PATH] [--refresh | --max-wait SECONDS] [--format bash]
nix-devshell-cached-exports --print-key [--dir PATH]
nix-devshell-cached-exports --print-cache-path [--dir PATH]
nix-devshell-cached-exports -h | --help
```

- `export` is the default and can be left out.
- `--dir PATH` acts as if run from `PATH` (default: the current directory).
- `--refresh` ignores the cache entry and any failure marker, and captures
  again.
- `--max-wait SECONDS`: on a cache miss, capture in the background and wait
  at most `SECONDS`. If the capture is still running then, print the last
  good environment (or nothing) with one line on stderr, and exit 0. The
  capture carries on, and the next call uses it. Without this option a call
  waits up to 15 minutes. It can't be combined with `--refresh`.
- `--format bash` is the only format; `fish` and `json` exit 2 with "not
  supported yet".
- `--print-key` prints the cache key; `--print-cache-path` prints the path
  of the cache entry. Neither captures anything.
- Outside a Nix project (no `flake.nix`, `shell.nix` or `default.nix` in the
  directory or above it), it prints nothing and exits 0, so it's safe to
  call anywhere.

### Output

```console
$ nix-devshell-cached-exports
# nix-devshell-cached-exports v3 root=/home/user/src/project key=8c1e0f3b9a… store=/nix/store/…-hello-2.12.3
if [ "${__NDCE_ROOT-}" != '/home/user/src/project' ]; then
…
fi
export CC='clang'
export FOO='multi
line '\''q'\'' $x'
export IN_NIX_SHELL='impure'
export PROJECT_ROOT='/home/user/src/project'
…
__ndce_a='/nix/store/…-hello-2.12.3/bin:/nix/store/…-clang-wrapper-21.1.8/bin:…'
…
export __NDCE_ROOT='/home/user/src/project'
export __NDCE_VARS='CC FOO IN_NIX_SHELL PROJECT_ROOT …'
```

- **Values** are single-quoted.
- **`PATH` and `XDG_DATA_DIRS`** get the devshell's entries in front of the
  caller's own. Loading twice adds no duplicates.
- **The first block** unloads a different project loaded earlier, using
  `__NDCE_ROOT` and `__NDCE_VARS`.
- **Shells:** the output works in bash 3.2, zsh and POSIX `sh`, and leaves
  no helper variables behind.

## How the cache works

### Files

```
${XDG_CACHE_HOME:-$HOME/.cache}/nix-devshell-cached-exports/<rootid>/
  <key>.sh        # a good capture: the exact text printed
  <key>.failed    # failure marker: the end of nix's stderr
  <key>.profile   # a flake's GC root, keeping its devshell in the store
  <hash>.v3.deps  # other files the .nix files with this hash depend on
  last-good       # symlink to the most recent good <key>.sh
  .lock           # flock target
```

- **`<rootid>`** comes from the project root's absolute path, so each git
  worktree has its own cache.
- **`<key>`** is a hash of the files that define the devshell:
  - `flake.nix` and `flake.lock`, and the `flake.lock` of any path-input
    sub-flake;
  - every tracked `*.nix` file, plus untracked ones for `shell.nix` /
    `default.nix` projects, since `nix-shell` reads those and a flake
    can't;
  - the project kind and `NDCE_FLAKE_SOURCE`.

  Changing any of them gives a new key and a new capture on the next call.

### Dependencies outside the `.nix` files

When the `.nix` files change, a rough scan finds other files the devshell
may read and adds them to the key:

- **files named by a relative path**, such as
  `builtins.readFile ./scripts/setup.sh`, relative to the `.nix` file;
- **known lock files** (`Cargo.lock`, `package-lock.json`, `yarn.lock`,
  `pnpm-lock.yaml`, `poetry.lock`, `uv.lock`, `go.sum`, `gomod2nix.toml`,
  `Gemfile.lock`, `mix.lock`, `deps-lock.json`, …), when they sit beside a
  `.nix` file that names them, or directly in a directory a path names (as
  `src = ./.;` names the project root). Deeper lock files, which mostly
  belong to examples and tests, are left out.
- **for `shell.nix` / `default.nix` projects that use `<...>` paths:**
  `NIX_PATH` and the channel profiles, so a channel update recaptures.

The scan prefers including too much: an extra file only costs a capture
when it changes. A cache hit doesn't scan. It reads the recorded list,
usually empty, and hashes those files.

### Pruning

Each successful capture deletes the project's cache files not written for
30 days, other than the new entry, `last-good` and `.lock`. A cache hit
doesn't count as a write, so an old entry that is still in use, such as
another branch's, can be pruned and cost one capture later. Cache
directories of deleted projects stay; remove them by hand.

### Store copies, GC roots and secrets

**Store copies.** `nix develop` on a flake in a git checkout copies every
tracked file into the store, once for each new state of the tree. In a large
repository that adds up. So a flake with a `flake.lock` is first captured
from a copy of only the files in the key (`nix develop path:<copy>`), still
run from the project root so shell hooks see the project as `$PWD`. The
capture falls back to the project itself when:

- the copy fails to evaluate;
- the devshell depends on the copy, i.e. the copy's store path is in the
  devshell's closure (for example `"${self}/src"` in a wrapper). `src =
  self;` in packages the devshell doesn't use costs nothing;
- a path reaches outside the project (`../shared`).

If capturing from the copy updates `flake.lock`, the project's is updated
too, as `nix develop` would. `NDCE_FLAKE_SOURCE=minimal` always uses the
copy, without checking; `tree` always uses the project. Set it per project
in `.claude/settings.json` (`"env": {"NDCE_FLAKE_SOURCE": "tree"}`) or in
`.envrc`.

**GC roots.** A flake's capture registers its devshell as a GC root
(`<key>.profile`), so garbage collection keeps a cached environment's store
paths. The root goes when its entry is pruned. A `shell.nix` capture has no
root. Either way, each entry names a store path its `PATH` needs, and a load
that finds it gone captures again.

**Secrets.** The cache directory is readable only by its owner, but it is
on disk, in backups, and readable by anything running as that user. A
devshell that reads a secret from a file in the project already has it on
disk, so every variable is cached by default. For a devshell that fetches a
secret when entered, from a keychain or password manager, set
`NDCE_SECRET_VARS` to space-separated patterns, matched in any case (such as
`*TOKEN* *SECRET* *PASSWORD*`). Matching variables are left out of the
cache, with a warning naming them, so load those another way.

### When a capture fails

If a capture fails, now or in an earlier attempt, and a last good entry
exists, that entry is printed, with one line on stderr:

```
nix-devshell-cached-exports: devshell capture failed for <root>; using the last good environment. Fix it, then run: nix-devshell-cached-exports --refresh
```

With no last good entry, it prints only the end of `nix`'s stderr and exits
1. Later calls print one line pointing at the failure marker instead. Either
way, `eval "$(…)"` never sees a half-loaded environment. A failed key isn't
retried until a devshell file changes or `--refresh` is given, so a broken
flake costs one capture, not one per command.

The capture runs under `env -i` with only the pass-through variables below,
from the project root, with stdin closed. Anything a shell hook prints is
discarded, and processes it leaves running don't hold the capture's lock.

A [numtide/devshell](https://github.com/numtide/devshell) installs a
launcher named after the devshell. If that name is also a command on the
caller's `PATH`, the launcher hides it, so running the command starts an
interactive devshell instead. The capture warns about this; the fix is to
give the devshell a name of its own (`devshell.name`).

### Overrides

These take space-separated names, with `*` as a wildcard:

- `NDCE_PASSTHROUGH`: variables passed into the capture (default: `HOME
  USER LOGNAME PATH TERM LANG LC_* TZ NIX_PATH NIX_CONFIG
  NIX_USER_CONF_FILES NIX_SSL_CERT_FILE SSL_CERT_FILE NIX_REMOTE
  SSH_AUTH_SOCK GIT_SSH GIT_SSH_COMMAND XDG_* TMPDIR`).
- `NDCE_EXCLUDE`: variables never exported, whatever the devshell does
  (default: `TMPDIR TMP TEMP TEMPDIR NIX_BUILD_TOP SHLVL PWD OLDPWD _
  __CF_USER_TEXT_ENCODING BASH_* BASHOPTS SHELLOPTS SHELL`). `SHELL` is
  excluded so a devshell's doesn't replace the caller's, and is always
  excluded when it is `/sbin/nologin` or `/usr/bin/false`.
- `NDCE_PREPEND_VARS`: colon-separated lists put in front of the caller's
  value instead of replacing it (default: `PATH XDG_DATA_DIRS`). An entry
  the caller already has doesn't count as added unless it is in the Nix
  store, since a caller started inside the devshell already has those.
- `NDCE_SECRET_VARS` and `NDCE_FLAKE_SOURCE`, described above.

## Measured

On 2026-09-26 with `hyperfine` (Apple Silicon, Nix 2.34.7, this
repository's numtide/devshell flake, whose startup hook installs skills).
The load average was 9–14, so treat small differences as noise. Cached rows
time a whole `bash -c 'eval "$(nix-devshell-cached-exports)"'`, bash
start-up included:

| Load | Time |
|---|---:|
| `nix develop --command true`, warm evaluation cache | 1.08 s |
| first capture after a flake change | 1.07–1.66 s |
| cached, from the root | 0.031 s |
| cached, from a subdirectory | 0.023 s |
| cached, from a worktree | 0.026 s |
| computing the cache key alone (`--print-key`) | 0.026 s |

An earlier prototype measured `nix develop --command true` at 3.6 s on
another numtide/devshell project, against 0.032–0.037 s for a cached load.

## Verified in Claude Code

From headless runs (`claude --plugin-dir <this repo> --model haiku -p …`):

- **2026-09-26, Claude Code 2.1.282:**
  - A plugin's `SessionStart` hook receives `CLAUDE_ENV_FILE`, and Claude
    Code runs that file before every Bash command, not once per session.
  - In a flake project whose shell hook writes a line to a marker file, the
    first Bash command already had the devshell, and the hook had run once.
    After `flake.nix` was edited, the next command had the change, with no
    restart, and the hook had run twice: one capture per change.
  - A subagent's Bash commands had the same devshell.
- **2026-09-27:** the same runs with the plugin and command installed from
  GitHub gave the same results.
- **2026-10-04, plugin 0.3.0:**
  - The `PreToolUse` reminder reached the model after `nix develop -c true`.
  - The `SubagentStart` context reached a general-purpose subagent.
  - `nix-devshell-cached-exports:worktree-worker` ran in a new worktree on
    its own branch, with `__NDCE_ROOT` set to that worktree and the
    devshell's tools on `PATH`. The unchanged worktree was removed
    afterwards.
- `claude plugin validate` passes. Its one warning, that `CLAUDE.md` at the
  repository root isn't loaded as plugin context, is expected: that file is
  for agents working on this repository.

## Development

See `AGENTS.md` for the checks to run and how to release a plugin change.

## Licence

MIT. See `LICENSE`.
