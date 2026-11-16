# Mirrors flake-worktree/flake.nix for the unit suite (stubbed nix). The
# stub sources this from the root, so $PWD here is the root.
#
# A devshell that declares its worktree hook, holds its root in values as a
# path prefix, and has per-worktree build variables named by a hash of the
# root, as `worktrees env` sets them. With an ODD_ROOT file in the root it
# also holds the root inside a longer name, which a seed can't rewrite.
export NDCE_WORKTREE_HOOK='echo hook >>"$PWD/marker"'
echo hook >>"$PWD/marker"
echo startup >>"$PWD/startup"
export FIXTURE_ROOT="$PWD"
export FIXTURE_DIRS="$PWD/sub:$PWD"
wt_id=${PWD##*/}-$(printf '%s' "$PWD" | sha256sum | cut -c1-8)
export WORKTREE_BUILDS_WT="$HOME/builds/wt/$wt_id"
export CARGO_TARGET_DIR="$WORKTREE_BUILDS_WT/target"
export WORKTREE_BUILDS_SET="CARGO_TARGET_DIR WORKTREE_BUILDS_WT"
unset wt_id
if [ -e "$PWD/ODD_ROOT" ]; then
  export FIXTURE_ODD="${PWD}-odd"
fi
