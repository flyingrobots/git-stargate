#!/usr/bin/env bash
# Publish a new trust state to a Stargate gateway, signed by you.
#
# Run inside a clone that has the gateway as a remote. The commit is built from
# DIR/{allowed_signers,bindings,admins}, parented on the gateway's current trust
# ref, signed with your configured signing key (gpg.format=ssh and
# user.signingkey), and pushed. The gateway accepts it only if you are an admin
# of the state it replaces.
#
# `--show` prints the gateway's current trust files instead.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: trust-update.sh [--remote NAME] [--trust-ref REF] -m MESSAGE DIR
       trust-update.sh [--remote NAME] [--trust-ref REF] --show
EOF
}
die() { printf 'trust-update: %s\n' "$*" >&2; exit 1; }

remote=stargate
trust_ref=refs/stargate/trust
message=''
show=0
dir=''

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) remote=${2:?}; shift 2 ;;
    --trust-ref) trust_ref=${2:?}; shift 2 ;;
    -m) message=${2:?}; shift 2 ;;
    --show) show=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) dir=$1; shift ;;
  esac
done

git fetch --quiet "$remote" "+$trust_ref:$trust_ref" ||
  die "could not fetch $trust_ref from $remote (has the operator initialised it?)"
parent=$(git rev-parse --verify "$trust_ref^{commit}")

if [ "$show" = 1 ]; then
  for f in allowed_signers bindings admins; do
    printf '==> %s\n' "$f"
    git cat-file blob "$parent:$f"
  done
  exit 0
fi

[ -n "$dir" ] && [ -n "$message" ] || { usage >&2; exit 2; }

entries=''
for f in allowed_signers bindings admins; do
  [ -f "$dir/$f" ] || die "$dir/$f is missing"
  entries+="100644 blob $(git hash-object -w "$dir/$f")"$'\t'"$f"$'\n'
done
tree=$(printf '%s' "$entries" | git mktree)
commit=$(git commit-tree -S -p "$parent" -m "$message" "$tree")
git push "$remote" "$commit:$trust_ref"
git update-ref "$trust_ref" "$commit" "$parent"
printf 'trust-update: %s -> %s\n' "$parent" "$commit"
