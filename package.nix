{
  lib,
  writeShellApplication,
  coreutils,
  findutils,
  git,
  gnugrep,
  util-linux,
}:

let
  # The command's own tools. They are not runtimeInputs: writeShellApplication
  # would export them in front of the caller's PATH, the devshell capture
  # would then start from that PATH, and a devshell that replaces PATH rather
  # than prepending to it would carry them into the output. Instead the
  # script puts them in front of PATH for itself only and hands the caller's
  # PATH, untouched, to the capture.
  #
  # `nix` / `nix-shell` are deliberately absent: the command enters the
  # devshell with the caller's own nix, the one that talks to their daemon
  # and reads their nix.conf.
  tools = [
    coreutils
    findutils # projects outside git
    git
    gnugrep
    util-linux # flock
  ];
in
(writeShellApplication {
  name = "nix-devshell-cached-exports";
  runtimeInputs = [ ];
  # The source file's shebang is dropped: it would no longer be on the first
  # line, and writeShellApplication supplies its own.
  text = ''
    __NDCE_TOOLS_PATH=${lib.escapeShellArg (lib.makeBinPath tools)}
  ''
  + lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./bin/nix-devshell-cached-exports);
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      description = "Print a Nix devshell's environment as cached export statements";
      homepage = "https://github.com/nhooey/nix-devshell-cached-exports";
      license = lib.licenses.mit;
      mainProgram = "nix-devshell-cached-exports";
      platforms = lib.platforms.unix;
    };
  })
