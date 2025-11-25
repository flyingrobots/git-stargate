#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=${1:-"$HOME/git/_blog-stargate.git"}
NAMESPACE=${NAMESPACE:-"refs/_blog/*"}
MIRROR_TO_HEADS=${MIRROR_TO_HEADS:-0}

log() { printf "[stargate] %s\n" "$*"; }

git init --bare "$REPO_DIR" >/dev/null 2>&1 || true

cat > "$REPO_DIR/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
EMPTY=0000000000000000000000000000000000000000
NS=${NAMESPACE:-"refs/_blog/*"}
while read -r old new ref; do
  case "$ref" in
    $NS)
      if [ "$old" != "$EMPTY" ]; then
        base=$(git merge-base "$old" "$new") || { echo "merge-base failed"; exit 1; }
        if [ "$base" != "$old" ]; then
          echo "Reject $ref: non-fast-forward ($old -> $new)"; exit 1; fi
      fi
      if ! git verify-commit "$new" >/dev/null 2>&1; then
        echo "Reject $ref: unsigned or unverified commit $new"; exit 1; fi
    ;;
  esac
done
exit 0
HOOK
chmod +x "$REPO_DIR/hooks/pre-receive"

cat > "$REPO_DIR/hooks/post-receive" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
REMOTE=origin
MIRROR_TO_HEADS=${MIRROR_TO_HEADS:-0}
NS=${NAMESPACE:-"refs/_blog/*"}
while read -r old new ref; do
  case "$ref" in
    $NS)
      if [ "$MIRROR_TO_HEADS" -eq 1 ]; then
        heads_ref="refs/heads/${ref#refs/_blog/}"
        git push "$REMOTE" "$ref:$heads_ref" || true
      else
        git push "$REMOTE" "$ref" || true
      fi
    ;;
  esac
done
exit 0
HOOK
chmod +x "$REPO_DIR/hooks/post-receive"

log "Stargate ready at $REPO_DIR (namespace: $NAMESPACE)"
log "Set origin for mirroring if desired: git --git-dir=$REPO_DIR remote add origin <url>"
log "To mirror into heads, run with MIRROR_TO_HEADS=1"
