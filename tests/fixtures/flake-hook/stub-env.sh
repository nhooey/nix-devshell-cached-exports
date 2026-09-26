# Mirrors flake-hook/flake.nix for the unit suite (stubbed nix). The stub
# sources this from a subshell already `cd`'d to the root, so $PWD here is
# the root — same as the real shellHook.
echo hook >>"$PWD/marker"
export FIXTURE_HOOK_PWD="$PWD"
