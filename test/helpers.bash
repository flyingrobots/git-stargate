# shellcheck shell=bash
# Test fixtures. Every test gets an isolated HOME and Git config, so the
# developer's own settings (commit.gpgsign, a signing key, hooksPath) can never
# make a push pass or fail for the wrong reason.

ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup_file() {
  export KEYS="$BATS_FILE_TMPDIR/keys"
  mkdir -p "$KEYS"
  for who in alice bob mallory; do
    ssh-keygen -q -t ed25519 -N '' -C "$who" -f "$KEYS/$who"
  done
}

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  : >"$GIT_CONFIG_GLOBAL"
  export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.com
  export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.com
  unset NAMESPACE MIRROR_TO_HEADS

  GW="$BATS_TEST_TMPDIR/gateway.git"
  WORK="$BATS_TEST_TMPDIR/work"
  git init --quiet "$WORK"
  git -C "$WORK" remote add stargate "$GW"
}

bootstrap() { "$ROOT/scripts/bootstrap.sh" "$@" "$GW"; }

signing() { printf '%s\n' -c gpg.format=ssh -c "user.signingkey=$KEYS/$1"; }

commit_as() { # who message
  # shellcheck disable=SC2046
  git -C "$WORK" $(signing "$1") commit --quiet --allow-empty -S -m "$2"
}

commit_unsigned() { git -C "$WORK" commit --quiet --allow-empty -m "$1"; }

push() { git -C "$WORK" push --quiet stargate "${2:-HEAD}:$1"; }

key_of() { cut -d' ' -f1,2 "$KEYS/$1.pub"; }

# make_trust DIR "admins" "principal ..." < bindings
make_trust() {
  local dir=$1 admins=$2 who
  mkdir -p "$dir"
  : >"$dir/allowed_signers"
  for who in $3; do printf '%s %s\n' "$who" "$(key_of "$who")" >>"$dir/allowed_signers"; done
  # shellcheck disable=SC2086 # split the space-separated admin list
  printf "%s\n" $admins >"$dir/admins"
  cat >"$dir/bindings"
}

# shellcheck disable=SC2154 # $status is set by bats `run`
refuted() { [ "$status" -ne 0 ]; }
