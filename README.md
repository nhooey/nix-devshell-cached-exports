# nix-devshell-cached-exports

Loading a Nix devshell with `nix develop --command …` costs 1–6 seconds every time.
`nix-devshell-cached-exports` enters the devshell once, records what it changed in the environment, and prints that as `export` statements from a cache.
Loading it again costs about 25–30 ms:

```console
$ cd ~/src/project && eval "$(nix-devshell-cached-exports)"
```

It comes with a Claude Code plugin that loads the devshell into every Bash command an agent runs, so agents don't need `nix develop` at all.

- **Shell hooks run once per capture, not once per load.** A new capture happens only when a file that defines the devshell changes.
- **No setup per project.** There is no `.envrc` and no allow step, and nothing is hooked into anyone's shell.
- **Any Nix project.** It handles flakes (`flake.nix`) and `shell.nix` / `default.nix` projects.

That is the difference from direnv with nix-direnv, which re-runs the devshell's shell hooks in every new shell and needs an `.envrc` per project.

## Install

Install the command first.
The plugin calls it by name.

- `nix profile install github:nhooey/nix-devshell-cached-exports`
- Or add `inputs.nix-devshell-cached-exports.packages.${system}.default` to your NixOS, nix-darwin or home-manager packages.
- Or try it with `nix run github:nhooey/nix-devshell-cached-exports`.

Then, in Claude Code:

```
/plugin marketplace add nhooey/nix-devshell-cached-exports
/plugin install nix-devshell-cached-exports@nix-devshell-cached-exports
```

and restart Claude Code (`claude --resume` keeps the conversation).

### Updating, and reloading the plugin

The command and the plugin update separately:

- **The command:** `nix profile upgrade nix-devshell-cached-exports`.
  The next Bash command uses it; nothing needs a restart.
- **The plugin:**

  ```
  /plugin marketplace update nix-devshell-cached-exports
  /plugin update nix-devshell-cached-exports@nix-devshell-cached-exports
  ```

  then restart Claude Code.

`/reload-plugins` is not enough on its own.
It reloads the copy Claude Code already has, and the lines the plugin adds to each session are written only when a session starts.
Claude Code also fetches a new copy only when the plugin's version number changes, so this repository bumps it with every change to the plugin (see `AGENTS.md`).

To check that a session has the current plugin, run `type cd` in a Bash command: it should print a shell function, not "shell builtin".

## The Claude Code plugin

### What each session gets

When a session starts, the plugin adds two lines to `$CLAUDE_ENV_FILE`, which Claude Code runs before every Bash command:

```bash
command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports --max-wait 10 </dev/null)"
cd() { builtin cd "$@" || return; command -v nix-devshell-cached-exports >/dev/null 2>&1 && eval "$(nix-devshell-cached-exports --max-wait 10 </dev/null)"; return 0; }
```

- **The first line** loads the devshell of the directory the command starts in.
- **The `cd` function** loads again after changing directory, so `cd .worktrees/topic && make` runs `make` with the worktree's devshell.
  Each `cd` costs a cached load, 20–40 ms.
- **Leaving a project** unloads it.
  Loading another project, or a directory outside any project, first removes the variables and `PATH` entries the previous project added.
  A tool from the wrong checkout is then "not found" rather than silently running against the wrong files.

The session start also begins the first capture in the background, so it overlaps with start-up.
A Bash command that arrives while a capture is running waits for it for at most 10 seconds.
After that it runs with the last good environment, or none before the first capture, and prints one line on stderr saying so.
The next command after the capture finishes gets the new environment.

If the command isn't installed, the plugin prints one line saying how to install it and otherwise does nothing.

### Subagents

- **Every subagent** loads the same lines, for its own working directory.
- **Context for subagents:** in a Nix project, a `SubagentStart` hook tells each subagent that its devshell is already loaded, so it runs tools directly instead of through `nix develop --command`.
  It also tells it that a `cd` inside `bash -c` or a script does not reload.
- **A reminder about `nix develop`:** when a Bash command runs `nix develop --command` or `nix-shell --run` on the devshell that's already loaded, a `PreToolUse` hook adds a reminder that it isn't needed.
  The command still runs, since another flake or devshell output can be a good reason.
- **The `nix-devshell-cached-exports:worktree-worker` agent** runs in its own git worktree (`isolation: worktree`).
  Every Bash command it runs starts there, so every command, and every process those commands start, has that worktree's devshell.
  Use it for changes made alongside other work.

## Caveats

- **A `cd` in a child process does not reload.** The `cd` function exists only in the shell that runs the Bash command.
  In `bash -c 'cd .worktrees/x && render'`, or a script that changes directory, the child keeps the parent's environment, `PRJ_ROOT` included, and can run one checkout's code against another's files without any error.
  Ways around it:
  - work from the right directory: start the session there, or use `EnterWorktree` or the `worktree-worker` agent;
  - make devshell commands find their checkout from where they run, instead of trusting an inherited `PRJ_ROOT`.
    See [Finding the checkout at run time](#finding-the-checkout-at-run-time).
- **The first load in a new directory waits.** A new worktree has its own cache, so the first command or `cd` there waits up to 10 seconds for a capture, and the devshell's shell hooks run there.
  A devshell that declares its worktree hooks is seeded from a sibling worktree instead, and waits only for those hooks.
  See [A new worktree](#a-new-worktree).
- **Shell hooks run once per capture.** A hook that must run for every command, such as one that fetches a short-lived secret or syncs files, does not fit.
  Neither does timing each command.
- **Session lines are written only at session start.** Installing, enabling or updating the plugin takes a restart to reach a session.
- **The command and the plugin are installed separately**, and nothing checks that their versions match.
- **Unloading is partial.** It removes the variables a project added and the entries it put in front of `PATH` and `XDG_DATA_DIRS`.
  A variable the caller already had before the load is not restored to its old value.
- **Some dependencies are invisible.** An unpinned `fetchTarball`, or a path built from strings, does not change the cache key.
  Run `nix-devshell-cached-exports --refresh` after changing what it points at.
- **Secrets are cached by default.** See [Secrets](#store-copies-gc-roots-and-secrets).
- **The `nix develop` reminder matches command text.** It misses commands with options between `nix develop` and `--command`, and anything inside a script.

### Finding the checkout at run time

Root variables such as numtide/devshell's `PRJ_ROOT` and devenv's `DEVENV_ROOT` are set once, when the devshell is entered.
Any process started from there inherits them, even after changing to another checkout.
A devshell command that should act on the checkout it runs in can find that checkout itself, each time it runs.
Nix has no built-in way to do this ([NixOS/nix#8034](https://github.com/NixOS/nix/issues/8034), [#6241](https://github.com/NixOS/nix/issues/6241)).
The two common ways:

**With git:**

```bash
root=$(git rev-parse --show-toplevel) || exit
PYTHONPATH="$root/src" exec python -m app "$@"
```

- Pros: nothing to add to the flake, and git is almost always on `PATH`.
  Inside a worktree it returns the worktree, even one nested inside the main checkout.
- Cons: it works only inside a git checkout, so not in a tarball or a `path:` copy, and it stops at the git root.
  A flake in a subdirectory of the repository needs `$root/subdir`.

**With [flake-root](https://github.com/srid/flake-root)**, a flake-parts module:

```nix
{
  inputs.flake-root.url = "github:srid/flake-root";
  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.flake-root.flakeModule ];
      perSystem = { config, lib, pkgs, ... }: {
        packages.app = pkgs.writeShellScriptBin "app" ''
          root=$(${lib.getExe config.flake-root.package}) || exit
          PYTHONPATH="$root/src" exec ${pkgs.python3}/bin/python -m app "$@"
        '';
      };
    };
}
```

Its `flake-root` program walks up from the current directory to the nearest `flake.nix` (or the file named by `flake-root.projectRootFile`), prints that directory, and exits 1 if there is none.

- Pros: it finds the flake itself, wherever it sits in the repository, and works without git.
  The walk is plain shell, with no `git` process.
- Cons: it needs flake-parts and one more input.
  Its marker check matches files only, so `projectRootFile = ".git"` would work in worktrees but not in a main checkout, where `.git` is a directory.

Don't use flake-root's `config.flake-root.devShell`: it sets `FLAKE_ROOT` in a shell hook, once at entry, so it goes stale just like `PRJ_ROOT`.
Use the program inside each command.

Either way, an interactive shell can keep using `PRJ_ROOT`; only commands that may run from another directory need to find the root themselves.

## Other ways to load it

### `.envrc`

```bash
watch_file flake.nix flake.lock shell.nix default.nix
eval "$(nix-devshell-cached-exports)"
```

`watch_file` only tells direnv when to run `.envrc` again; the cache decides whether that needs a new capture.

### `BASH_ENV`

For other non-interactive bash shells, point `BASH_ENV` at a file with the same `eval`.
Guard it, since every non-interactive bash reads `BASH_ENV`, including the devshell's own wrapper scripts:

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
nix-devshell-cached-exports --prune [--keep-days N] [--dry-run]
nix-devshell-cached-exports --forget ROOT [--dry-run]
nix-devshell-cached-exports --print-config | --print-defaults
nix-devshell-cached-exports -h | --help
```

- `export` is the default and can be left out.
- `--dir PATH` acts as if run from `PATH` (default: the current directory).
- `--refresh` ignores the cache entry and any failure marker, and captures again.
- `--max-wait SECONDS`: on a cache miss, capture in the background and wait at most `SECONDS`.
  If the capture is still running then, print the last good environment (or nothing) with one line on stderr, and exit 0.
  The capture carries on, and the next call uses it.
  Without this option a call waits up to 15 minutes.
  It can't be combined with `--refresh`.
- `--format bash` is the only format; `fish` and `json` exit 2 with "not supported yet".
- `--print-key` prints the cache key; `--print-cache-path` prints the path of the cache entry.
  Neither captures anything.
- `--prune` sweeps the cache folders of every project, not only the current one's (see [Pruning](#pruning)).
  `--keep-days N` (default 7) sets how recent an entry must be to stay; `--dry-run` prints the paths it would delete and deletes nothing.
  It ends with a one-line summary.
- `--forget ROOT` deletes the cache folder of one project root, such as a worktree being removed, with its entries and GC roots (see [A new worktree](#a-new-worktree)).
  `--dry-run` lists the folder's files instead.
- `--print-config` prints the settings in effect, each with where it came from; `--print-defaults` prints the shipped defaults file (see [Settings](#settings)).
- Outside a Nix project (no `flake.nix`, `shell.nix` or `default.nix` in the directory or above it), it prints nothing and exits 0, so it's safe to call anywhere.

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
- **`PATH` and `XDG_DATA_DIRS`** get the devshell's entries in front of the caller's own.
  Loading twice adds no duplicates.
- **The first block** unloads a different project loaded earlier, using `__NDCE_ROOT` and `__NDCE_VARS`.
- **Shells:** the output works in bash 3.2, zsh and POSIX `sh`, and leaves no helper variables behind.

## How the cache works

### Files

```
${XDG_CACHE_HOME:-$HOME/.cache}/nix-devshell-cached-exports/<rootid>/
  <key>.sh        # a good capture: the exact text printed
  <key>.failed    # failure marker: the end of nix's stderr
  <key>.profile   # a flake's GC root, keeping its devshell in the store
  <key>.profile-<n>-link  # the profile generation <key>.profile points at
  <key>.warn      # a capture's warning, shown on the next load
  <hash>.v3.deps  # other files the .nix files with this hash depend on
  last-good       # symlink to the most recent good <key>.sh
  .lock           # flock target, held by a capture and by --prune
  .<name>.XXXXXX  # a temp file, left only by a call that was killed
```

An entry is the files named `<key>.*`.
Its `.deps` record is named for the hash of the `.nix` files alone, which is the key itself unless the devshell depends on other files.

- **`<rootid>`** comes from the project root's absolute path, so each git worktree has its own cache.
- **`<key>`** is a hash of the files that define the devshell:
  - `flake.nix` and `flake.lock`, and the `flake.lock` of any path-input sub-flake;
  - every tracked `*.nix` file, plus untracked ones for `shell.nix` / `default.nix` projects, since `nix-shell` reads those and a flake can't;
  - the project kind and the `flake-source` setting.

  Changing any of them gives a new key and a new capture on the next call.

### Dependencies outside the `.nix` files

When the `.nix` files change, a rough scan finds other files the devshell may read and adds them to the key:

- **files named by a relative path**, such as `builtins.readFile ./scripts/setup.sh`, relative to the `.nix` file;
- **known lock files** (`Cargo.lock`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `poetry.lock`, `uv.lock`, `go.sum`, `gomod2nix.toml`, `Gemfile.lock`, `mix.lock`, `deps-lock.json`, …), when they sit beside a `.nix` file that names them, or directly in a directory a path names (as `src = ./.;` names the project root).
  Deeper lock files, which mostly belong to examples and tests, are left out.
- **for `shell.nix` / `default.nix` projects that use `<...>` paths:** `NIX_PATH` and the channel profiles, so a channel update recaptures.

The scan prefers including too much: an extra file only costs a capture when it changes.
A cache hit doesn't scan.
It reads the recorded list, usually empty, and hashes those files.

### A new worktree

The key holds no path, so another worktree of the same clone (as `git worktree list` names them) with an entry for the same key has already captured the same devshell.
On a miss, the first such entry that passes these checks is copied, with its root replaced by the new one, instead of a capture:

- **The devshell declares its worktree hooks** by exporting `NDCE_WORKTREE_HOOK`: shell code for what its startup does inside the root, such as linking `.agents/skills/`, or an empty value for nothing.
  The rest of its startup counts as setting the environment, which the copy already holds.
  The hook runs in the new root with the copied environment loaded.
  A devshell that doesn't declare it is captured in full, since its hooks may act inside the root.
  If the hook fails, so does the seed, and a full capture follows.
- **The old root appears only as a path prefix:** after a quote, `:`, `=`, a space or a newline, and before `/`, a quote, `:`, a space or a newline.
  A value that holds it some other way, inside a longer name or a word, can't be rewritten safely, so the new root is captured in full.
  A value derived from the root without holding it, such as a hash of it, isn't caught by this check.
- **The per-worktree build variables are left out.** `git-worktree-manager env` sets `WORKTREE_MANAGER_BUILD_ROOT`, `WORKTREE_MANAGER_BUILD_DIR` and `WORKTREE_MANAGER_EXPORTED` on every run, and the languages' variables that `WORKTREE_MANAGER_EXPORTED` names, some of which end in a hash of the worktree's path that a rewrite can't fix.
  The copy unsets the first three, and those the list names that the entry itself exports and that `passthrough` and `prepend-vars` don't cover, so it never unsets `PATH` or another of the caller's variables.
  It then runs `git-worktree-manager env --shell sh` in the new root, before the worktree hook, for the new root's own, so a seeded worktree never builds into its sibling's folder.
  The new root is captured in full instead, so it never goes without the variables a capture would set, when:
  - the entry holds any of the first three but not `WORKTREE_MANAGER_EXPORTED`, whose list says which variables are the program's;
  - `git-worktree-manager` isn't on the `PATH` with the entry loaded;
  - `git-worktree-manager env` fails;
  - the `WORKTREE_MANAGER_EXPORTED` it prints names other variables than the sibling's, whatever their order, since the entry's record of the variables to unload and the languages detected are the sibling's;
  - it prints any line but one `export NAME='VALUE'` (each quote in the value written `'\''`) for each of the first three names and the listed ones that aren't the caller's.
    After the copy's unset, that is all it prints, unless Gradle is detected and `GRADLE_OPTS` lacks Gradle's caching flag, when the new root is captured in full, as a capture sets it.
- **The entry holds no `WORKTREE_BUILDS_SET`,** the list of per-worktree build variables of the retired `worktrees` program, which nothing here sets.
- **The entry is live,** its devshell still in the store, and names its own root.
  The seeded root gets its own GC root for that devshell.

`--refresh` never seeds.
A seeded entry is the new root's own from then on: the next load is a hit, and a change to the `.nix` files captures in full.

Whatever removes a worktree can remove its cache folder too, with `nix-devshell-cached-exports --forget <root>`.
It takes the folder's lock without waiting and refuses while a capture holds it.
A root already gone from disk is taken as written, so pass the real path, without symlinks.

### Pruning

Each successful capture deletes the project's cache files not written for 30 days, other than the new entry, `last-good` and `.lock`.
A cache hit doesn't count as a write, so an old entry that is still in use, such as another branch's, can be pruned and cost one capture later.

That only reaches the project being captured.
A project you stop visiting keeps every entry it ever had, and with it a GC root per version of its `.nix` files.
`nix-devshell-cached-exports --prune` sweeps every project's folder instead.
In each, it keeps:

- the newest entry (by its `<key>.sh`), and the one `last-good` names;
- every entry with a file written within `--keep-days N` days (default 7);
- the newest `.deps` record, since one named for a hash that is not a key can't be matched to its entry by name;
- `.lock` and `last-good`, always, and temp files younger than `N` days.

Everything else goes: `.sh`, `.failed`, `.warn`, `.deps` and the GC root (`<key>.profile` and its `-<n>-link`).
It takes each folder's lock without waiting, so it never deletes from a folder a capture is writing to; it skips that folder and says so.
With `--dry-run` it takes no lock, lists the paths that would go and deletes nothing.
Either way it ends with one line:

```console
$ nix-devshell-cached-exports --prune --dry-run | tail -n 1
nix-devshell-cached-exports: would remove 673 entries and 517 GC roots (2220 files) in 181 of 575 project folders, keeping each one's newest entry and those from the last 7 days
```

The folder of a deleted project keeps its newest entry; remove it with `--forget ROOT`.

**On a schedule (nix-darwin).** The flake exports a module that runs it weekly from a launchd user agent:

```nix
{
  imports = [ inputs.nix-devshell-cached-exports.darwinModules.default ];
  services.nix-devshell-cached-exports.prune = {
    enable = true;
    user = "alice";   # whose ~/.cache it prunes
    # keepDays = 7;
    # interval = [ { Weekday = 7; Hour = 3; Minute = 0; } ];  # Sunday 03:00
    # package = inputs.nix-devshell-cached-exports.packages.${system}.default;
  };
}
```

`interval` is launchd's `StartCalendarInterval`, where Sunday is 7 (or 0), as in `nix.gc.interval`.
The default runs 15 minutes before nix-darwin's default `nix.gc` (Sunday 03:15), so that collection frees the devshells the prune let go of.
If the Mac is asleep at both times, launchd runs both on waking, in no set order; the prune's roots then go at the following collection.
The agent loads for every user who logs in but only prunes as `user`, logging to `~/Library/Logs/nix-devshell-cached-exports-prune.log`.

### Store copies, GC roots and secrets

**Store copies.** `nix develop` on a flake in a git checkout copies every tracked file into the store, once for each new state of the tree.
In a large repository that adds up.
So a flake with a `flake.lock` is first captured from a copy of only the files in the key (`nix develop path:<copy>`), still run from the project root so shell hooks see the project as `$PWD`.
The capture falls back to the project itself when:

- the copy fails to evaluate;
- the devshell depends on the copy, i.e. the copy's store path is in the devshell's closure (for example `"${self}/src"` in a wrapper).
  `src = self;` in packages the devshell doesn't use costs nothing;
- a path reaches outside the project (`../shared`).

A capture never writes `flake.lock`, from the copy or the project: it runs `nix develop --no-write-lock-file`, so a missing or incomplete lock is resolved in memory for that capture only, and a `nix flake update` run while a capture is going is kept (the next load captures again under the new lock).
Lock the flake yourself (`nix flake lock`) to pin its inputs.
The `flake-source` setting (see [Settings](#settings)) picks this: `auto`, the default, as above; `minimal` always uses the copy, without checking; `tree` always uses the project.
Set it per project in `.claude/settings.json` (`"env": {"NDCE_FLAKE_SOURCE": "tree"}`) or in `.envrc`.

**GC roots.** A flake's capture registers its devshell as a GC root (`<key>.profile`), so garbage collection keeps a cached environment's store paths.
The root goes when its entry is pruned, by a capture of that project or by `--prune` (see [Pruning](#pruning)): the link in the cache folder is deleted, and Nix drops the dangling entry in `/nix/var/nix/gcroots/auto` at its next collection, along with any store paths only it kept.
While an entry stays, its root holds the devshell through every collection, `--delete-older-than` or not.
A `shell.nix` capture has no root.
Either way, each entry names a store path its `PATH` needs, and a load that finds it gone captures again.

**Secrets.** The cache directory is readable only by its owner, but it is on disk, in backups, and readable by anything running as that user.
A devshell that reads a secret from a file in the project already has it on disk, so every variable is cached by default.
For a devshell that fetches a secret when entered, from a keychain or password manager, set `secret-vars` (see [Settings](#settings)) to patterns, matched in any case (such as `*TOKEN* *SECRET* *PASSWORD*`).
Matching variables are left out of the cache, with a warning naming them, so load those another way.

### When a capture fails

If a capture fails, now or in an earlier attempt, and a last good entry exists, that entry is printed, with one line on stderr:

```
nix-devshell-cached-exports: devshell capture failed for <root>; using the last good environment. Fix it, then run: nix-devshell-cached-exports --refresh
```

With no last good entry, it prints only the end of `nix`'s stderr and exits 1.
Later calls print one line pointing at the failure marker instead.
Either way, `eval "$(…)"` never sees a half-loaded environment.
A failed key isn't retried until a devshell file changes or `--refresh` is given, so a broken flake costs one capture, not one per command.

The capture runs under `env -i` with only the pass-through variables below, from the project root, with stdin closed.
Anything a shell hook prints is discarded, and processes it leaves running don't hold the capture's lock.

A [numtide/devshell](https://github.com/numtide/devshell) installs a launcher named after the devshell.
If that name is also a command on the caller's `PATH`, the launcher hides it, so running the command starts an interactive devshell instead.
The capture warns about this; the fix is to give the devshell a name of its own (`devshell.name`).

### Settings

Every setting and its default is in [`share/nix-devshell-cached-exports/defaults.toml`](share/nix-devshell-cached-exports/defaults.toml), which ships with the command and documents each one; `nix-devshell-cached-exports --print-defaults` prints it.
Three layers apply, each over the one before:

1. the shipped defaults;
2. your config file, `~/.config/nix-devshell-cached-exports/config.toml` (under `$XDG_CONFIG_HOME` when that is set), holding only the settings you change;
3. an `NDCE_*` variable per setting, as space-separated words, for one project (`.claude/settings.json` or `.envrc`) or one call.

For example:

```toml
secret-vars = ["*TOKEN*", "*SECRET*", "*PASSWORD*"]
flake-source = "tree"
```

A list replaces the default list whole, and `[]` empties it.
A key the defaults file doesn't have, a value of the wrong kind or a key set twice is an error naming the file and line, and stops every call until it's fixed.
The files take a subset of TOML: quoted strings without escapes, and lists of them, which may span lines.
`--print-config` prints the settings in effect, each with the layer it came from.

The settings, with their variables:

- `passthrough` (`NDCE_PASSTHROUGH`): variables passed into the capture.
- `exclude` (`NDCE_EXCLUDE`): variables never exported, whatever the devshell does.
  `SHELL` is in the default list so a devshell's doesn't replace the caller's, and is always excluded when it is `/sbin/nologin` or `/usr/bin/false`.
- `prepend-vars` (`NDCE_PREPEND_VARS`): colon-separated lists put in front of the caller's value instead of replacing it.
  An entry the caller already has doesn't count as added unless it is in the Nix store, since a caller started inside the devshell already has those.
- `secret-vars` (`NDCE_SECRET_VARS`) and `flake-source` (`NDCE_FLAKE_SOURCE`), described above.

The first four take variable names, with `*` as a wildcard.

## Measured

On 2026-09-26 with `hyperfine` (Apple Silicon, Nix 2.34.7, this repository's numtide/devshell flake, whose startup hook installs skills).
The load average was 9–14, so treat small differences as noise.
Cached rows time a whole `bash -c 'eval "$(nix-devshell-cached-exports)"'`, bash start-up included:

| Load | Time |
|---|---:|
| `nix develop --command true`, warm evaluation cache | 1.08 s |
| first capture after a flake change | 1.07–1.66 s |
| cached, from the root | 0.031 s |
| cached, from a subdirectory | 0.023 s |
| cached, from a worktree | 0.026 s |
| computing the cache key alone (`--print-key`) | 0.026 s |

A new worktree's first load, on 2026-11-17 (Apple Silicon, Nix 2.34.9), in three repositories whose numtide/devshell flakes have the skills reconcile as their one startup hook.
The main checkout had a capture for the same key.
The machine's load average was 17–36 on 12 cores, so the times are 2–3 times what an idle machine gives; compare the rows, not the numbers.
Steps after the first capture ran 3 times, and the fastest counts:

| Load | writing-skills | dendrometer | github-config |
|---|---:|---:|---:|
| full capture, the worktree's first | 35.4 s | 42.7 s | 13.6 s |
| … of which `nix develop` | 31.6 s | 40.5 s | 12.2 s |
| `nix print-dev-env`: evaluation and build, evaluation cache warm | 0.65 s | 1.33 s | 1.09 s |
| the startup hook (the skills reconcile) | 7.7 s | 11.5 s | 5.3 s |
| seeded from a sibling, the reconcile as its worktree hook | 11.1 s | 10.9 s | 4.7 s |
| the reconcile alone, run again | 6.9 s | 7.4 s | 3.4 s |
| the next load, a hit | 0.19 s | 0.13 s | 0.11 s |

Most of a full capture is `nix develop` beyond its startup hook: evaluating and building from the copy of the flake's files (see [Store copies](#store-copies-gc-roots-and-secrets)).
On the checkout itself, with the evaluation cache warm, the same takes about a second; why the copy costs so much more wasn't measured.
A seed skips evaluation, the build and every hook but the worktree's own, which leaves the reconcile as nearly all of a seeded load.

## Verified in Claude Code

Headless runs (`claude --plugin-dir <this repo> --model haiku -p …`), with the plugin and command loaded both from a checkout and from GitHub, show:

- A plugin's `SessionStart` hook receives `CLAUDE_ENV_FILE`, and Claude Code runs that file before every Bash command, not once per session.
- In a flake project whose shell hook writes a line to a marker file, the first Bash command already has the devshell, and the hook has run once.
  After `flake.nix` is edited, the next command has the change, with no restart, and the hook has run twice: one capture per change.
- A subagent's Bash commands have the same devshell.
- The `PreToolUse` reminder reaches the model after `nix develop -c true`.
- The `SubagentStart` context reaches a general-purpose subagent.
- `nix-devshell-cached-exports:worktree-worker` runs in a new worktree on its own branch, with `__NDCE_ROOT` set to that worktree and the devshell's tools on `PATH`.
  An unchanged worktree is removed afterwards.
- `claude plugin validate` passes.
  Its one warning, that `CLAUDE.md` at the repository root isn't loaded as plugin context, is expected: that file is for agents working on this repository.

## Development

See `AGENTS.md` for the checks to run and how to release a plugin change.

## Licence

MIT.
See `LICENSE`.
