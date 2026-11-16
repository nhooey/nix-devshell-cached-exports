{
  description = "flake fixture that declares its worktree hook and has per-worktree build variables";

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
              wt_id=''${PWD##*/}-$(printf '%s' "$PWD" | sha256sum | cut -c1-8)
              export WORKTREE_BUILDS_WT="$HOME/builds/wt/$wt_id"
              export CARGO_TARGET_DIR="$WORKTREE_BUILDS_WT/target"
              export WORKTREE_BUILDS_SET="CARGO_TARGET_DIR WORKTREE_BUILDS_WT"
              unset wt_id
              if [ -e "$PWD/ODD_ROOT" ]; then
                export FIXTURE_ODD="''${PWD}-odd"
              fi
            '';
          };
        }
      );
    };
}
