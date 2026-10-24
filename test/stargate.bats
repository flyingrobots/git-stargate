#!/usr/bin/env bats
# Behaviour of the Stargate hooks, end to end through real pushes.

load helpers

trust_update_as() { # who dir message
  git -C "$WORK" config gpg.format ssh
  git -C "$WORK" config user.signingkey "$KEYS/$1"
  (cd "$WORK" && "$ROOT/scripts/trust-update.sh" -m "$3" "$2")
}

warp_trust() { # dir: writers sign only their own lane; alice administers
  make_trust "$1" alice "alice bob mallory" <<'EOF'
# pattern                          principals
refs/warp/*/writers/{principal}    {principal}
refs/_blog/*                       alice
EOF
}

# --- configuration -------------------------------------------------------

@test "a namespace given to bootstrap is enforced at push time without any environment" {
  bootstrap --namespace 'refs/kv/*'
  commit_unsigned "unsigned"

  run push refs/kv/a
  refuted
  [[ $output == *"unsigned or its signature is not trusted"* ]]

  run push refs/_blog/a # no longer a guarded namespace
  [ "$status" -eq 0 ]
}

@test "the legacy NAMESPACE variable is honoured at bootstrap time" {
  NAMESPACE='refs/kv/*' bootstrap
  [ "$(git --git-dir="$GW" config --get-all stargate.namespace)" = 'refs/kv/*' ]
}

@test "re-running bootstrap keeps the configured namespaces" {
  bootstrap --namespace 'refs/kv/*'
  bootstrap
  [ "$(git --git-dir="$GW" config --get-all stargate.namespace)" = 'refs/kv/*' ]
}

# --- fast-forward and deletion --------------------------------------------

@test "a non-fast-forward update is rejected" {
  bootstrap --no-require-signed
  commit_unsigned one
  push refs/_blog/a
  git -C "$WORK" reset --quiet --hard "$(git -C "$WORK" commit-tree -m other "$(git -C "$WORK" write-tree)")"

  run git -C "$WORK" push --force stargate HEAD:refs/_blog/a
  refuted
  [[ $output == *"non-fast-forward"* ]]
}

@test "deletion is rejected with a clear message unless allowed" {
  bootstrap --no-require-signed
  commit_unsigned one
  push refs/_blog/a

  run git -C "$WORK" push stargate :refs/_blog/a
  refuted
  [[ $output == *"deletion is disabled"* ]]

  git --git-dir="$GW" config stargate.allowDelete true
  run git -C "$WORK" push stargate :refs/_blog/a
  [ "$status" -eq 0 ]
}

# --- signatures without a trust ref ---------------------------------------

@test "every new commit must be signed, not just the tip" {
  bootstrap
  printf '%s %s\n' alice "$(key_of alice)" >"$BATS_TEST_TMPDIR/signers"
  git --git-dir="$GW" config gpg.ssh.allowedSignersFile "$BATS_TEST_TMPDIR/signers"
  commit_unsigned "buried"
  commit_as alice "signed tip"

  run push refs/_blog/a
  refuted
  [[ $output == *"unsigned or its signature is not trusted"* ]]
}

@test "without a trust ref, a signature the server trusts is accepted with a warning" {
  bootstrap
  printf '%s %s\n' alice "$(key_of alice)" >"$BATS_TEST_TMPDIR/signers"
  git --git-dir="$GW" config gpg.ssh.allowedSignersFile "$BATS_TEST_TMPDIR/signers"
  commit_as alice "signed"

  run push refs/_blog/a
  [ "$status" -eq 0 ]
  [[ $output == *"accepting any signature the server trusts"* ]]
}

# --- trust ref: bindings --------------------------------------------------

@test "a writer may sign their own lane" {
  warp_trust "$BATS_TEST_TMPDIR/trust"
  bootstrap --namespace 'refs/warp/*' --trust-dir "$BATS_TEST_TMPDIR/trust"
  commit_as alice "alice writes"

  run push refs/warp/g/writers/alice
  [ "$status" -eq 0 ]
}

@test "a trusted key may not write someone else's lane" {
  warp_trust "$BATS_TEST_TMPDIR/trust"
  bootstrap --namespace 'refs/warp/*' --trust-dir "$BATS_TEST_TMPDIR/trust"
  commit_as mallory "mallory impersonates"

  run push refs/warp/g/writers/alice
  refuted
  [[ $output == *"signed by mallory, who may not write this ref"* ]]
}

@test "a key absent from the trust ref is rejected even if the server's own config trusts it" {
  make_trust "$BATS_TEST_TMPDIR/trust" alice alice <<<'refs/_blog/* *'
  bootstrap --trust-dir "$BATS_TEST_TMPDIR/trust"
  printf '%s %s\n' bob "$(key_of bob)" >"$BATS_TEST_TMPDIR/server-signers"
  git --git-dir="$GW" config gpg.ssh.allowedSignersFile "$BATS_TEST_TMPDIR/server-signers"
  commit_as bob "bob is unknown to the trust ref"

  run push refs/_blog/a
  refuted
  [[ $output == *"not trusted"* ]]
}

@test "a namespace ref with no binding fails closed" {
  warp_trust "$BATS_TEST_TMPDIR/trust"
  bootstrap --namespace 'refs/warp/*' --namespace 'refs/kv/*' --trust-dir "$BATS_TEST_TMPDIR/trust"
  commit_as alice "alice"

  run push refs/kv/a
  refuted
  [[ $output == *"no binding"* ]]
}

@test "a merged-in commit from another writer cannot enter a lane" {
  warp_trust "$BATS_TEST_TMPDIR/trust"
  bootstrap --namespace 'refs/warp/*' --trust-dir "$BATS_TEST_TMPDIR/trust"
  commit_as bob "bob's own work"
  push refs/warp/g/writers/bob
  commit_as alice "alice on top of bob"

  run push refs/warp/g/writers/alice
  refuted
  [[ $output == *"signed by bob, who may not write this ref"* ]]
}

# --- trust ref: updates ---------------------------------------------------

@test "an admin can add a writer, and the new writer can then push" {
  warp_trust "$BATS_TEST_TMPDIR/full"
  make_trust "$BATS_TEST_TMPDIR/trust" alice "alice" <"$BATS_TEST_TMPDIR/full/bindings"
  bootstrap --namespace 'refs/warp/*' --trust-dir "$BATS_TEST_TMPDIR/trust"

  commit_as bob "bob before enrolment"
  run push refs/warp/g/writers/bob
  refuted
  [[ $output == *"unsigned or its signature is not trusted"* ]]

  warp_trust "$BATS_TEST_TMPDIR/next"
  run trust_update_as alice "$BATS_TEST_TMPDIR/next" "enrol bob and mallory"
  [ "$status" -eq 0 ]

  run push refs/warp/g/writers/bob
  [ "$status" -eq 0 ]

  run bash -c "cd '$WORK' && '$ROOT/scripts/trust-update.sh' --show"
  [ "$status" -eq 0 ]
  [[ $output == *"bob ssh-ed25519"* ]]
}

@test "a non-admin cannot change the trust ref" {
  warp_trust "$BATS_TEST_TMPDIR/trust"
  bootstrap --namespace 'refs/warp/*' --trust-dir "$BATS_TEST_TMPDIR/trust"
  make_trust "$BATS_TEST_TMPDIR/next" mallory "alice bob mallory" <"$BATS_TEST_TMPDIR/trust/bindings"

  run trust_update_as mallory "$BATS_TEST_TMPDIR/next" "mallory takes over"
  refuted
  [[ $output == *"signed by mallory, who is not an admin"* ]]
}

@test "a trust update that leaves no usable admin is rejected" {
  warp_trust "$BATS_TEST_TMPDIR/trust"
  bootstrap --namespace 'refs/warp/*' --trust-dir "$BATS_TEST_TMPDIR/trust"
  make_trust "$BATS_TEST_TMPDIR/next" carol "alice bob" <"$BATS_TEST_TMPDIR/trust/bindings"

  run trust_update_as alice "$BATS_TEST_TMPDIR/next" "lock everyone out"
  refuted
  [[ $output == *"admin carol has no key in allowed_signers"* ]]
}

@test "the trust ref cannot be created or deleted by push" {
  bootstrap
  commit_as alice "forged trust"
  run push refs/stargate/trust
  refuted
  [[ $output == *"initialised by the operator"* ]]

  warp_trust "$BATS_TEST_TMPDIR/trust"
  bootstrap --trust-dir "$BATS_TEST_TMPDIR/trust" 2>/dev/null || true
  run git -C "$WORK" push stargate :refs/stargate/trust
  refuted
  [[ $output == *"cannot be deleted"* ]]
}

@test "bootstrap refuses to overwrite an existing trust ref" {
  warp_trust "$BATS_TEST_TMPDIR/trust"
  bootstrap --trust-dir "$BATS_TEST_TMPDIR/trust"
  run bootstrap --trust-dir "$BATS_TEST_TMPDIR/trust"
  refuted
  [[ $output == *"already exists"* ]]
}

# --- mirroring ------------------------------------------------------------

@test "heads mirroring keeps the full ref name, so it cannot overwrite a real branch" {
  git init --quiet --bare "$BATS_TEST_TMPDIR/upstream.git"
  bootstrap --no-require-signed --namespace 'refs/_blog/*' --mirror-heads
  git --git-dir="$GW" remote add origin "$BATS_TEST_TMPDIR/upstream.git"
  commit_unsigned "post"

  push refs/_blog/main
  run git --git-dir="$BATS_TEST_TMPDIR/upstream.git" for-each-ref --format='%(refname)'
  [ "$output" = refs/heads/_mirror/_blog/main ]
}

@test "a failed mirror does not fail the push and is recorded" {
  bootstrap --no-require-signed
  git --git-dir="$GW" remote add origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  commit_unsigned "post"

  run push refs/_blog/a
  [ "$status" -eq 0 ]
  [[ $output == *"mirroring refs/_blog/a to origin failed"* ]]
  grep -q ' refs/_blog/a ' "$GW/stargate/mirror-failures"
}

# --- review findings ------------------------------------------------------

@test "a replacement object cannot substitute the trust state" {
  make_trust "$BATS_TEST_TMPDIR/trust" alice alice <<<'refs/_blog/* *'
  bootstrap --trust-dir "$BATS_TEST_TMPDIR/trust"
  trust=$(git --git-dir="$GW" rev-parse refs/stargate/trust)

  # A forged trust state that enrols mallory, pushed as a replacement for the
  # real trust commit. refs/replace/* is outside every guarded namespace.
  make_trust "$BATS_TEST_TMPDIR/forged" mallory "alice mallory" <<<'refs/_blog/* *'
  entries=''
  for f in allowed_signers bindings admins; do
    entries+="100644 blob $(git -C "$WORK" hash-object -w "$BATS_TEST_TMPDIR/forged/$f")"$'\t'"$f"$'\n'
  done
  forged=$(git -C "$WORK" commit-tree -m forged "$(printf '%s' "$entries" | git -C "$WORK" mktree)")
  git -C "$WORK" push --quiet stargate "$forged:refs/replace/$trust"

  commit_as mallory "mallory after the replacement"
  run push refs/_blog/a
  refuted
  [[ $output == *"not trusted"* ]]
}

@test "a guarded ref must point at a commit, signed or not" {
  make_trust "$BATS_TEST_TMPDIR/trust" alice alice <<<'refs/_blog/* *'
  bootstrap --trust-dir "$BATS_TEST_TMPDIR/trust"
  blob=$(printf 'not a commit\n' | git -C "$WORK" hash-object -w --stdin)
  tree=$(git -C "$WORK" mktree </dev/null)

  run git -C "$WORK" push stargate "$blob:refs/_blog/blob"
  refuted
  [[ $output == *"is a blob, not a commit"* ]]

  git --git-dir="$GW" config stargate.requireSigned false
  run git -C "$WORK" push stargate "$tree:refs/_blog/tree"
  refuted
  [[ $output == *"is a tree, not a commit"* ]]
}
