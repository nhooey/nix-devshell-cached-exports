{
  description = "flake fixture whose shellHook writes a marker file in the root and exports a variable derived from $PWD";

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
              echo hook >> "$PWD/marker"
              export FIXTURE_HOOK_PWD="$PWD"
            '';
          };
        }
      );
    };
}
