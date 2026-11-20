# Mirrors flake-worktree/flake.nix for the unit suite (stubbed nix). The
# stub sources this from the root, so $PWD here is the root.
#
# A devshell that declares its worktree hook and holds its root in values
# as a path prefix. With a BUILD_VARIABLES file in the root it also has
# per-worktree build variables named by a hash of the root, as
# `git-worktree-manager env` sets them for a Rust project; with a
# NO_EXPORTED_LIST file as well, it has all of them but their list,
# WORKTREE_MANAGER_EXPORTED, with a LIST_NAMES_PATH file, that list also
# names PATH, and with a LIST_NAMES_TZ file, it sets TZ and the list names
# it. With an OLD_BUILDS_SET file it has the WORKTREE_BUILDS_SET of the
# retired `worktrees` program. With an ODD_ROOT file in the root it also
# holds the root inside a longer name, which a seed can't rewrite.
export NDCE_WORKTREE_HOOK='echo hook >>"$PWD/marker"'
echo hook >>"$PWD/marker"
echo startup >>"$PWD/startup"
export FIXTURE_ROOT="$PWD"
export FIXTURE_DIRS="$PWD/sub:$PWD"
if [ -e "$PWD/BUILD_VARIABLES" ]; then
  wt_id=${PWD##*/}-$(printf '%s' "$PWD" | sha256sum | cut -c1-8)
  export WORKTREE_MANAGER_BUILD_ROOT="$HOME/builds"
  export WORKTREE_MANAGER_BUILD_DIR="$HOME/builds/wt/$wt_id"
  export CARGO_BUILD_BUILD_DIR="$HOME/builds/shared/cargo-build"
  export CARGO_TARGET_DIR="$WORKTREE_MANAGER_BUILD_DIR/target"
  export WORKTREE_MANAGER_EXPORTED="CARGO_BUILD_BUILD_DIR:CARGO_TARGET_DIR"
  unset wt_id
  if [ -e "$PWD/NO_EXPORTED_LIST" ]; then
    unset WORKTREE_MANAGER_EXPORTED
  fi
  if [ -e "$PWD/LIST_NAMES_PATH" ]; then
    export WORKTREE_MANAGER_EXPORTED="$WORKTREE_MANAGER_EXPORTED:PATH"
  fi
  if [ -e "$PWD/LIST_NAMES_TZ" ]; then
    export TZ=NDCE0
    export WORKTREE_MANAGER_EXPORTED="$WORKTREE_MANAGER_EXPORTED:TZ"
  fi
fi
if [ -e "$PWD/OLD_BUILDS_SET" ]; then
  export WORKTREE_BUILDS_SET="CARGO_TARGET_DIR"
fi
if [ -e "$PWD/ODD_ROOT" ]; then
  export FIXTURE_ODD="${PWD}-odd"
fi
