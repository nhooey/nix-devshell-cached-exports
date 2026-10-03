{
  description = "Print a Nix devshell's environment as cached export statements, loadable by any shell for the cost of a cat";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    # `agent-skill-flake` is the builder library, not a skill — it provides the
    # `flakeModules.devshellSkills` flake-parts module that wires the dev-shell
    # skill set in below. That module bundles numtide/devshell, so this flake
    # needs no `devshell` input of its own. The skill sources themselves are NOT
    # inputs here: they live only in the `skills-devshell/` sub-flake's lock,
    # which this dev shell invokes at RUNTIME (never as a root input), keeping
    # this flake a leaf with zero skill inputs.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      systems,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        inputs.agent-skill-flake.flakeModules.devshellSkills
        inputs.treefmt-nix.flakeModule
      ];

      # numtide/devshell installs its launcher as $DEVSHELL_DIR/bin/<name>,
      # so the name must not be the command's: inside this devshell it would
      # shadow the real command, and with no arguments start an interactive
      # shell that waits on stdin.
      agent-skill-flake.devshellSkills = {
        name = "nix-devshell-cached-exports-dev";
      };

      perSystem =
        { pkgs, config, ... }:
        let
          testInputs = with pkgs; [
            bash
            bats
            coreutils
            git
            gnugrep
            util-linux
          ];
        in
        {
          packages.default = pkgs.callPackage ./package.nix { };

          checks = {
            shellcheck =
              pkgs.runCommand "nix-devshell-cached-exports-shellcheck"
                { nativeBuildInputs = [ pkgs.shellcheck ]; }
                ''
                  cd ${./.}
                  shellcheck --shell=bash bin/nix-devshell-cached-exports hooks/*.sh scripts/* tests/stubs/*
                  touch $out
                '';

            # Sandbox-safe suite: `nix` and `nix-shell` are stubs, since nix
            # cannot enter a devshell inside a build. `tests/e2e.bats` covers
            # the same scenarios with real nix, run locally via `test-e2e`.
            unit = pkgs.runCommand "nix-devshell-cached-exports-unit" { nativeBuildInputs = testInputs; } ''
              cp -r ${./.} src
              chmod -R u+w src
              cd src
              patchShebangs bin hooks tests
              export HOME=$TMPDIR/home
              mkdir -p "$HOME"
              bats tests/unit.bats tests/hooks.bats
              touch $out
            '';

            package = config.packages.default;
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              shfmt = {
                enable = true;
                indent_size = 2;
              };
            };
            settings.formatter.shfmt.includes = [
              "bin/nix-devshell-cached-exports"
              "scripts/*"
              "tests/stubs/*"
            ];
          };

          devshells.default = {
            packages = testInputs ++ [
              pkgs.shellcheck
              pkgs.shfmt
            ];

            commands = [
              {
                category = "dev";
                name = "lint";
                help = "Run shellcheck on the command, hooks and test stubs";
                command = ''
                  cd "$PRJ_ROOT" &&
                    shellcheck --shell=bash bin/nix-devshell-cached-exports hooks/*.sh scripts/* tests/stubs/*
                '';
              }
              {
                category = "dev";
                name = "bump-plugin-version";
                help = "Set the plugin version, needed for any change to hooks/";
                command = ''"$PRJ_ROOT/scripts/bump-plugin-version" "$@"'';
              }
              {
                category = "dev";
                name = "test";
                help = "Run the sandbox-safe unit suite (stubbed nix)";
                command = ''cd "$PRJ_ROOT" && bats tests/unit.bats tests/hooks.bats "$@"'';
              }
              {
                category = "dev";
                name = "test-e2e";
                help = "Run the end-to-end suite against real nix";
                command = ''cd "$PRJ_ROOT" && bats tests/e2e.bats "$@"'';
              }
            ];
          };
        };
    };
}
