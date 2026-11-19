#!/usr/bin/env bats
# Agents must not stage changes they did not name, and the tests they run
# are no exception: every test and script here names the paths it adds.
# This text search fails on a line under tests/ or scripts/ that adds or
# stages with -A (alone or among other flags), --all or -u, or with ., ./,
# :/ or * as its last path, or that commits with -a. A quoted or unusual
# spelling can pass it, and a comment holding one of these fails it.

@test "no test or script stages changes it does not name" {
  cd "$(dirname "${BATS_TEST_FILENAME}")/.."
  pattern='git( -C [^ ]+)* ((add|stage)( -[^ ]+)* (-[^- ]*A|--all|(-u|--update|\.|\./|:/|\*) *($|[;&|)]))|commit( -[^ ]+)* (--all|-[^- ]*a))'
  run grep -rnE -- "$pattern" tests scripts
  [ "$status" -eq 1 ] || {
    echo "$output"
    return 1
  }
}
