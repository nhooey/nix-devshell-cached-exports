# The `darwin-module` check in flake.nix: modules/darwin.nix, evaluated
# with lib.evalModules against stubs of the two nix-darwin options it
# touches (launchd.user.agents, which it sets, and users.users.<name>.home,
# which it reads), rather than against nix-darwin itself. That would add an
# input, and lock nodes, for every consumer of this flake for one check, and
# a whole darwin system evaluation per check run. The cost is that
# nix-darwin's own types for serviceConfig go unchecked here; the module
# sets only keys they document. `alice` and `bob` are placeholder users.
{
  pkgs,
  darwinModule,
  package,
}:
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
  # users.users.<name>.home, which nix-darwin types as a path.
  usersStub = {
    options.users.users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.home = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
          };
        }
      );
      default = { };
    };
  };
  evalWith =
    extra: settings:
    (lib.evalModules {
      modules = [
        launchdStub
        usersStub
        darwinModule
        { _module.args.pkgs = pkgs; }
        { services.nix-devshell-cached-exports.prune = settings; }
        extra
      ];
    }).config;
  eval = evalWith { };
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
  # A home set as an unquoted path, as a configuration may write it.
  pathHome =
    (evalWith { users.users.bob.home = /Users/bob; } {
      enable = true;
      user = "bob";
    }).launchd.user.agents.nix-devshell-cached-exports-prune.serviceConfig;
  # (Without context: lib.hasInfix cannot match a store path.)
  script = builtins.unsafeDiscardStringContext (builtins.elemAt agent.ProgramArguments 2);
  exe = builtins.unsafeDiscardStringContext (lib.getExe package);
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
assert pathHome.EnvironmentVariables.HOME == "/Users/bob";
assert lib.hasInfix "--prune --keep-days 3" (builtins.elemAt tuned.ProgramArguments 2);
assert
  tuned.StartCalendarInterval == {
    Weekday = 6;
    Hour = 2;
  };
pkgs.writeText "nix-devshell-cached-exports-darwin-module" (builtins.toJSON agent)
