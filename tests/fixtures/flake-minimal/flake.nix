{
  description = "minimal flake fixture: a bare devshell, no shellHook, no PATH changes";

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
            FIXTURE_MINIMAL = "1";
          };
        }
      );
    };
}
