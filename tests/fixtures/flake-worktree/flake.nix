{
  description = "flake fixture that declares its worktree hook and, with a BUILD_VARIABLES file, has per-worktree build variables";

  inputs.nixpkgs.url = "@NIXPKGS_URL@";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems =
        f: nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ] f;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShellNoCC {
            shellHook = ''
              export NDCE_WORKTREE_HOOK='echo hook >>"$PWD/marker"'
              echo hook >>"$PWD/marker"
              echo startup >>"$PWD/startup"
              export FIXTURE_ROOT="$PWD"
              export FIXTURE_DIRS="$PWD/sub:$PWD"
              if [ -e "$PWD/BUILD_VARIABLES" ]; then
                wt_id=''${PWD##*/}-$(printf '%s' "$PWD" | sha256sum | cut -c1-8)
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
                export FIXTURE_ODD="''${PWD}-odd"
              fi
            '';
          };
        }
      );
    };
}
