# Mirrors flake-path/flake.nix for the unit suite (stubbed nix).
export PATH="/fixture/bin-added:$PATH"
export XDG_DATA_DIRS="/fixture/share-added${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
