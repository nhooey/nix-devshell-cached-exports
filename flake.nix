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

      # services.nix-devshell-cached-exports.prune: a weekly `--prune` from a
      # launchd user agent (modules/darwin.nix).
      flake.darwinModules.default = import ./modules/darwin.nix { inherit (inputs) self; };

      perSystem =
        { pkgs, config, ... }:
        let
          testInputs = with pkgs; [
            bash
            bats
            coreutils
            git
            gnugrep
            jq
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
              patchShebangs bin hooks scripts tests
              export HOME=$TMPDIR/home
              mkdir -p "$HOME"
              export NDCE_TEST_PLUGIN_SOURCE=${./.}
              bats tests/unit.bats tests/hooks.bats
              touch $out
            '';

            package = config.packages.default;

            # The darwin module, evaluated with lib.evalModules against a stub
            # of the one nix-darwin option it sets (launchd.user.agents),
            # rather than against nix-darwin itself: that would add an input,
            # and lock nodes, for every consumer of this flake for one check,
            # and a whole darwin system evaluation per check run. The cost is
            # that nix-darwin's own types for serviceConfig go unchecked
            # here; the module sets only keys they document.
            darwin-module =
              let
                inherit (pkgs) lib;
                launchdStub = {
                  options.launchd.user.agents = lib.mkOption {
                    type = lib.types.attrsOf (
                      lib.types.submodule {
                        options.serviceConfig = lib.mkOption {
                          type = lib.types.attrsOf lib.types.anything;
                          default = { };
                        };
                      }
                    );
                    default = { };
                  };
                };
                eval =
                  settings:
                  (lib.evalModules {
                    modules = [
                      launchdStub
                      inputs.self.darwinModules.default
                      { _module.args.pkgs = pkgs; }
                      { services.nix-devshell-cached-exports.prune = settings; }
                    ];
                  }).config;
                agentOf =
                  settings: (eval settings).launchd.user.agents.nix-devshell-cached-exports-prune.serviceConfig;
                agent = agentOf {
                  enable = true;
                  user = "alice";
                };
                tuned = agentOf {
                  enable = true;
                  user = "alice";
                  keepDays = 3;
                  interval = {
                    Weekday = 6;
                    Hour = 2;
                  };
                };
                # (Without context: lib.hasInfix cannot match a store path.)
                script = builtins.unsafeDiscardStringContext (builtins.elemAt agent.ProgramArguments 2);
                exe = builtins.unsafeDiscardStringContext (lib.getExe config.packages.default);
              in
              assert (eval { }).launchd.user.agents == { };
              assert
                agent.StartCalendarInterval == [
                  {
                    Weekday = 7;
                    Hour = 3;
                    Minute = 0;
                  }
                ];
              assert lib.hasInfix "${exe} --prune --keep-days 7" script;
              assert lib.hasInfix "= alice ] || exit 0" script;
              assert agent.EnvironmentVariables.HOME == "/Users/alice";
              assert agent.StandardOutPath == "/Users/alice/Library/Logs/nix-devshell-cached-exports-prune.log";
              assert lib.hasInfix "--prune --keep-days 3" (builtins.elemAt tuned.ProgramArguments 2);
              assert
                tuned.StartCalendarInterval == {
                  Weekday = 6;
                  Hour = 2;
                };
              pkgs.writeText "nix-devshell-cached-exports-darwin-module" (builtins.toJSON agent);
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
