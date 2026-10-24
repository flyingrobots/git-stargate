#!/usr/bin/env bash
# Create or update a Stargate gateway: a bare repository whose hooks guard
# custom ref namespaces and mirror accepted updates upstream.
#
# Settings are written into the gateway's Git config, where the hooks read
# them at push time. Re-running updates the hooks and replaces the settings
# given on the command line; an existing trust ref is never overwritten.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: bootstrap.sh [options] [REPO_DIR]

  REPO_DIR                 bare gateway repo (default ~/git/_blog-stargate.git)
  --namespace GLOB         guarded ref glob; repeatable (default refs/_blog/*)
  --trust-ref REF          trust ref (default refs/stargate/trust)
  --trust-dir DIR          initialise the trust ref from DIR/{allowed_signers,bindings,admins}
  --mirror-remote NAME     remote to mirror accepted refs to (default origin)
  --mirror-heads           mirror under refs/heads/_mirror/ so GitHub shows them
  --mirror-heads-prefix P  prefix for --mirror-heads (default refs/heads/_mirror/)
  --allow-delete           permit deleting namespace refs
  --no-require-signed      accept unsigned commits (fast-forward rule still applies)

Environment (kept for compatibility): NAMESPACE, MIRROR_TO_HEADS=1.
EOF
}

log() { printf '[stargate] %s\n' "$*"; }
die() { printf '[stargate] error: %s\n' "$*" >&2; exit 1; }

repo_dir="$HOME/git/_blog-stargate.git"
namespaces=()
trust_ref=''
trust_dir=''
mirror_remote=''
mirror_heads=''
mirror_heads_prefix=''
allow_delete=''
require_signed=''

[ -n "${NAMESPACE-}" ] && namespaces+=("$NAMESPACE")
[ "${MIRROR_TO_HEADS-0}" = 1 ] && mirror_heads=true

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) namespaces+=("${2:?--namespace needs a glob}"); shift 2 ;;
    --trust-ref) trust_ref=${2:?--trust-ref needs a ref}; shift 2 ;;
    --trust-dir) trust_dir=${2:?--trust-dir needs a directory}; shift 2 ;;
    --mirror-remote) mirror_remote=${2:?--mirror-remote needs a name}; shift 2 ;;
    --mirror-heads) mirror_heads=true; shift ;;
    --mirror-heads-prefix) mirror_heads_prefix=${2:?--mirror-heads-prefix needs a prefix}; shift 2 ;;
    --allow-delete) allow_delete=true; shift ;;
    --no-require-signed) require_signed=false; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) repo_dir=$1; shift ;;
  esac
done

src_hooks="$(cd "$(dirname "$0")/../hooks" && pwd)"

git init --quiet --bare "$repo_dir"
export GIT_DIR="$repo_dir"

for hook in pre-receive post-receive stargate-lib.sh; do
  install -m 0755 "$src_hooks/$hook" "$repo_dir/hooks/$hook"
done

if [ ${#namespaces[@]} -gt 0 ]; then
  git config --unset-all stargate.namespace || true
  for ns in "${namespaces[@]}"; do git config --add stargate.namespace "$ns"; done
elif ! git config --get stargate.namespace >/dev/null; then
  git config --add stargate.namespace 'refs/_blog/*'
fi
[ -n "$trust_ref" ] && git config stargate.trustRef "$trust_ref"
[ -n "$mirror_remote" ] && git config stargate.mirrorRemote "$mirror_remote"
[ -n "$mirror_heads" ] && git config stargate.mirrorHeads "$mirror_heads"
[ -n "$mirror_heads_prefix" ] && git config stargate.mirrorHeadsPrefix "$mirror_heads_prefix"
[ -n "$allow_delete" ] && git config stargate.allowDelete "$allow_delete"
[ -n "$require_signed" ] && git config stargate.requireSigned "$require_signed"

effective_trust_ref=$(git config --get stargate.trustRef || printf 'refs/stargate/trust')

if [ -n "$trust_dir" ]; then
  if git rev-parse --verify --quiet "$effective_trust_ref" >/dev/null; then
    die "$effective_trust_ref already exists; update it with a signed push (scripts/trust-update.sh)"
  fi
  entries=''
  for f in allowed_signers bindings admins; do
    [ -f "$trust_dir/$f" ] || die "$trust_dir/$f is missing"
    entries+="100644 blob $(git hash-object -w "$trust_dir/$f")"$'\t'"$f"$'\n'
  done
  grep -qvE '^[[:space:]]*(#|$)' "$trust_dir/admins" || die "$trust_dir/admins lists no admins"
  tree=$(printf '%s' "$entries" | git mktree)
  commit=$(GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-stargate-operator} \
    GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-stargate@localhost} \
    GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-stargate-operator} \
    GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-stargate@localhost} \
    git commit-tree -m 'stargate: initialise trust' "$tree")
  # An empty old value makes update-ref refuse if the ref appeared meanwhile.
  git update-ref "$effective_trust_ref" "$commit" ''
  log "initialised $effective_trust_ref at $commit"
fi

log "Stargate ready at $repo_dir"
log "namespaces: $(git config --get-all stargate.namespace | paste -sd ' ' -)"
if git rev-parse --verify --quiet "$effective_trust_ref" >/dev/null; then
  log "trust: $effective_trust_ref"
else
  log "trust: none ($effective_trust_ref absent); any signature the server trusts is accepted"
fi
git remote get-url "$(git config --get stargate.mirrorRemote || printf origin)" >/dev/null 2>&1 ||
  log "mirroring off; add a remote to enable it: git --git-dir=$repo_dir remote add origin <url>"
