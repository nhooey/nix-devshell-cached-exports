# nix-darwin module: a weekly `nix-devshell-cached-exports --prune`, so the
# GC roots of old cache entries (one per version of each project's .nix
# files, in every project ever visited) stop keeping old devshells from the
# garbage collector. Exported by the flake as `darwinModules.default`; `self`
# is the flake, for the default package.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nix-devshell-cached-exports.prune;

  user =
    if cfg.user != null then
      cfg.user
    else
      throw "services.nix-devshell-cached-exports.prune.user must name the user whose cache to prune";

  # The user's home: users.users.<user>.home when the configuration declares
  # it, else the macOS default.
  declaredHome = config.users.users.${user}.home or null;
  home = if declaredHome == null then "/Users/${user}" else declaredHome;
  logFile = "${home}/Library/Logs/nix-devshell-cached-exports-prune.log";

  # launchd loads a user agent for every user who logs in; only the cache's
  # own user prunes it.
  script = ''
    [ "$(/usr/bin/id -un)" = ${lib.escapeShellArg user} ] || exit 0
    exec ${lib.getExe cfg.package} --prune --keep-days ${toString cfg.keepDays}
  '';
in
{
  options.services.nix-devshell-cached-exports.prune = {
    enable = lib.mkEnableOption ''
      a weekly prune of the nix-devshell-cached-exports cache: in every
      project's cache folder, the entries (and their GC roots) other than the
      newest and those written within `keepDays` days are deleted, so the
      next garbage collection can free their devshells
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "inputs.nix-devshell-cached-exports.packages.\${system}.default";
      description = "The nix-devshell-cached-exports package to run.";
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = ''
        The user whose cache (`~/.cache/nix-devshell-cached-exports`) is
        pruned. The agent runs as that user, and logs to
        `~/Library/Logs/nix-devshell-cached-exports-prune.log`.
      '';
    };

    keepDays = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 7;
      description = ''
        Keep entries written within this many days, as well as each
        project's newest entry (`--keep-days`).
      '';
    };

    interval = lib.mkOption {
      type = with lib.types; either (attrsOf int) (listOf (attrsOf int));
      # launchd counts Sunday as both 0 and 7; nix.gc.interval uses 7.
      default = [
        {
          Weekday = 7;
          Hour = 3;
          Minute = 0;
        }
      ];
      description = ''
        When to prune, as launchd's `StartCalendarInterval`. The default,
        Sunday 03:00, comes before nix-darwin's default `nix.gc.interval`
        (Sunday 03:15), so that collection frees what the prune let go of.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    launchd.user.agents.nix-devshell-cached-exports-prune.serviceConfig = {
      ProgramArguments = [
        "/bin/sh"
        "-c"
        script
      ];
      StartCalendarInterval = cfg.interval;
      # launchd gives an agent no HOME of its own to rely on.
      EnvironmentVariables.HOME = home;
      StandardOutPath = logFile;
      StandardErrorPath = logFile;
      ProcessType = "Background";
      LowPriorityIO = true;
    };
  };
}
