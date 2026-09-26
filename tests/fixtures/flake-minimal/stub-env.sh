# Mirrors flake-minimal/flake.nix for the unit suite (stubbed nix).
#
# Also exercises 2 things a real `nix develop` does that the command must
# handle even though this fixture's real flake doesn't need to:
#   - it points TMPDIR/TMP/TEMP/TEMPDIR at a fresh scratch dir, which must
#     NOT leak into the caller's environment (excluded by name);
#   - FIXTURE_TRICKY carries a newline, single and double quotes, a `$`,
#     a backslash and spaces, to check the output round-trips them exactly.
export FIXTURE_MINIMAL=1

export TMPDIR=/nix-stub/tmp-changed
export TMP=/nix-stub/tmp-changed
export TEMP=/nix-stub/tmp-changed
export TEMPDIR=/nix-stub/tmp-changed

export FIXTURE_TRICKY=$'line one\nline "two" with '\''single'\'' quotes, a $DOLLAR, a \\backslash, and spaces'
