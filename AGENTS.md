# Working on this repository

It has two parts, installed separately:

- **The command:** `bin/nix-devshell-cached-exports`, packaged by
  `package.nix` and installed with `nix profile`.
- **The Claude Code plugin:** `.claude-plugin/`, `hooks/` and `agents/`,
  installed with `/plugin`.

`README.md` describes how both behave.

## Checks

There is no CI. Before committing, run:

- `nix flake check`: shellcheck, formatting, the package build, and the
  unit and hook suites (`nix` is stubbed). Stage new files first, since
  Nix only sees tracked ones.
- `nix develop -c bats tests/e2e.bats`: the same scenarios against real
  Nix. Each capture takes seconds, so this isn't part of the flake check.

With the plugin loaded, the devshell's tools (`bats`, `shellcheck`,
`shfmt`) are already on `PATH`. Run `bats tests/unit.bats tests/hooks.bats`
directly. Inside `bash -c`, `test` is the shell builtin, not the devshell's
`test` command.

## Changing the plugin

After any change under `hooks/` or `agents/`, run
`scripts/bump-plugin-version` (`minor` by default; also `patch`, `major` or
`X.Y.Z`). Its header explains why, and the hook tests fail until it's done.

To try a change in Claude Code before releasing it, start a session with
`claude --plugin-dir .`. A headless run such as
`claude --plugin-dir . --model haiku -p '…'` can confirm that a hook's
output reaches the model.

Once it's pushed, people who have the plugin update it with
`/plugin marketplace update nix-devshell-cached-exports`, then
`/plugin update nix-devshell-cached-exports@nix-devshell-cached-exports`,
then a restart. A change to the command alone needs
`nix profile upgrade nix-devshell-cached-exports` instead.

## Conventions

- **Branches and commits:** the default branch is `master`; commit messages
  follow Conventional Commits.
- **Cache format versions:** a change to the output or cache entry format
  bumps `FORMAT_VERSION` in `bin/nix-devshell-cached-exports`, and a change
  to the dependency records bumps `DEPS_VERSION`. Every project then
  captures once more.
- **Cross-shell output:** the command's output must run in bash 3.2, zsh
  and POSIX `sh`. The unit suite runs it in `/bin/bash` (3.2 on macOS) and,
  when installed, zsh; nothing tests `sh` itself.
