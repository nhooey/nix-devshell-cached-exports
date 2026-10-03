# Agent notes

Two parts, installed separately: the command (`bin/`, installed with
`nix profile`) and the Claude Code plugin (`hooks/`, `.claude-plugin/`,
installed with `/plugin`). README.md describes both.

## Checks

There is no CI. Before committing, run these in the devshell (`nix develop`):

- `test`: unit and hook suites, stubbed nix
- `test-e2e`: the same scenarios against real nix
- `lint`, and `nix fmt`
- `nix flake check`

## Changing the plugin

After any change to `hooks/`, run `bump-plugin-version` (`minor` by
default; also `patch`, `major` or `X.Y.Z`). Its header explains why, and
`test` fails until it's done.

Once pushed, people already using it update with:

```
/plugin marketplace update nix-devshell-cached-exports
/plugin update nix-devshell-cached-exports@nix-devshell-cached-exports
```

followed by a restart. A command change needs `nix profile upgrade
nix-devshell-cached-exports` instead.

## Conventions

- Default branch `master`; Conventional Commits.
- A change to the cache format bumps `FORMAT_VERSION` in
  `bin/nix-devshell-cached-exports`, and one to the deps records bumps
  `DEPS_VERSION`.
