{
  pkgs ?
    import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/@NIXPKGS_REV@.tar.gz")
      { },
}:
pkgs.mkShellNoCC {
  FIXTURE_SHELL_NIX = "1";
}
