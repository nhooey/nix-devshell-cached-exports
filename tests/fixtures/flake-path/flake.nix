{
  description = "flake fixture whose devshell prepends to PATH and XDG_DATA_DIRS";

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
          # Prepending by hand in shellHook, rather than via nativeBuildInputs,
          # keeps this fixture's PATH/XDG_DATA_DIRS additions fixed and
          # predictable for the assertions in unit.bats/e2e.bats.
          default = pkgs.mkShellNoCC {
            shellHook = ''
              export PATH="/fixture/bin-added:$PATH"
              export XDG_DATA_DIRS="/fixture/share-added''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
            '';
          };
        }
      );
    };
}
