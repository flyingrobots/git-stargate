#!/usr/bin/env bats
# Unit tests for binding pattern matching in hooks/stargate-lib.sh.

setup() {
  # shellcheck source=hooks/stargate-lib.sh
  . "$BATS_TEST_DIRNAME/../hooks/stargate-lib.sh"
  BINDINGS="$BATS_TEST_TMPDIR/bindings"
}

matches() { [[ $2 =~ $(sg_glob_to_regex "$1") ]]; }

# Bats ignores the status of a `!`-negated command unless it is the last one in
# a test, so negative checks use this explicit failure instead.
refutes() {
  if matches "$1" "$2"; then
    printf 'pattern %s unexpectedly matched %s\n' "$1" "$2" >&2
    return 1
  fi
}

@test "regex metacharacters in a pattern are literal" {
  matches 'refs/a.b/*' refs/a.b/c
  refutes 'refs/a.b/*' refs/aXb/c
  matches 'refs/x+y/(z)' 'refs/x+y/(z)'
  refutes 'refs/x+y/(z)' refs/xxy/z
}

@test "* spans path segments and {principal} spans exactly one" {
  matches 'refs/warp/*/writers/{principal}' refs/warp/g/sub/writers/alice
  refutes 'refs/warp/*/writers/{principal}' refs/warp/g/writers/alice/extra
}

@test "patterns are anchored at both ends" {
  refutes 'refs/_blog/*' refs/heads/refs/_blog/x
  refutes 'refs/kv/a' refs/kv/ab
}

@test "the first matching binding wins and {principal} resolves to the captured segment" {
  printf '%s\n' '# comment' '' 'refs/warp/*/writers/{principal} {principal},ops' 'refs/* nobody' >"$BINDINGS"
  run sg_allowed_principals refs/warp/g/writers/alice "$BINDINGS"
  [ "$status" -eq 0 ]
  [ "$output" = $'alice\nops' ]
}

@test "an unmatched ref has no principals" {
  printf '%s\n' 'refs/_blog/* alice' >"$BINDINGS"
  run sg_allowed_principals refs/kv/a "$BINDINGS"
  [ "$status" -eq 1 ]
}
