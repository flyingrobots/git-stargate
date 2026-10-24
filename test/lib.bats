#!/usr/bin/env bats
# Unit tests for binding pattern matching in hooks/stargate-lib.sh.

setup() {
  # shellcheck source=hooks/stargate-lib.sh
  . "$BATS_TEST_DIRNAME/../hooks/stargate-lib.sh"
  BINDINGS="$BATS_TEST_TMPDIR/bindings"
}

matches() { [[ $2 =~ $(sg_glob_to_regex "$1") ]]; }

@test "regex metacharacters in a pattern are literal" {
  matches 'refs/a.b/*' refs/a.b/c
  ! matches 'refs/a.b/*' refs/aXb/c
  matches 'refs/x+y/(z)' 'refs/x+y/(z)'
  ! matches 'refs/x+y/(z)' refs/xxy/z
}

@test "* spans path segments and {principal} spans exactly one" {
  matches 'refs/warp/*/writers/{principal}' refs/warp/g/sub/writers/alice
  ! matches 'refs/warp/*/writers/{principal}' refs/warp/g/writers/alice/extra
}

@test "patterns are anchored at both ends" {
  ! matches 'refs/_blog/*' refs/heads/refs/_blog/x
  ! matches 'refs/kv/a' refs/kv/ab
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
