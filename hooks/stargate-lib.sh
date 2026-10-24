# shellcheck shell=bash
# Shared helpers for the Stargate hooks. Sourced, never executed directly.
#
# Configuration lives in the gateway repository's own Git config, written by
# scripts/bootstrap.sh, so it is present when a hook runs. (Hooks do not inherit
# the operator's shell environment.)
#
#   stargate.namespace          multi-valued ref glob, e.g. refs/_blog/*
#   stargate.trustRef           trust ref (default refs/stargate/trust)
#   stargate.requireSigned      true|false (default true)
#   stargate.allowDelete        true|false (default false)
#   stargate.mirrorRemote       remote to mirror to (default origin)
#   stargate.mirrorHeads        true|false (default false)
#   stargate.mirrorHeadsPrefix  default refs/heads/_mirror/

# Policy must judge the objects actually stored. A pusher can create
# refs/replace/<oid>, and Git would then read their object in place of <oid>,
# for example a forged trust tree. Disable replacement for every Git command
# the hooks run.
export GIT_NO_REPLACE_OBJECTS=1

SG_ZERO_OID=$(git hash-object --stdin </dev/null | sed 's/./0/g')

sg_log() { printf 'stargate: %s\n' "$*" >&2; }

sg_config() { git config --get "stargate.$1" || printf '%s' "${2-}"; }

sg_config_bool() {
  local v
  v=$(git config --type=bool --get "stargate.$1" 2>/dev/null) || v=$2
  [ "$v" = true ]
}

sg_trust_ref() { sg_config trustRef refs/stargate/trust; }

sg_namespaces() {
  git config --get-all stargate.namespace || printf '%s\n' 'refs/_blog/*'
}

# Is $1 inside a configured namespace? Globs use shell `case` semantics, so `*`
# also matches `/`.
sg_in_namespace() {
  local ref=$1 ns
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    # shellcheck disable=SC2254 # the pattern is intentionally unquoted
    case "$ref" in $ns) return 0 ;; esac
  done < <(sg_namespaces)
  return 1
}

# Convert a binding pattern to an anchored ERE.
#   *            any characters, including /
#   {principal}  exactly one path segment, captured
# Everything else is literal.
sg_glob_to_regex() {
  local g=$1 out='' c
  while [ -n "$g" ]; do
    case "$g" in
      '{principal}'*) out+='([^/]+)'; g=${g#'{principal}'} ;;
      '*'*) out+='.*'; g=${g#'*'} ;;
      *)
        c=${g:0:1}
        case "$c" in
          '.' | '[' | ']' | '^' | '$' | "\\" | '+' | '?' | '(' | ')' | '|' | '{' | '}') out+="\\$c" ;;
          *) out+="$c" ;;
        esac
        g=${g:1}
        ;;
    esac
  done
  printf '^%s$' "$out"
}

# Print the principals permitted to sign commits for ref $1 under the bindings
# file $2, one per line. `*` means any principal in allowed_signers. Returns 1
# when no binding matches, so unbound refs fail closed.
sg_allowed_principals() {
  local ref=$1 bindings=$2 pattern spec rest re p
  # `|| [ -n ... ]` keeps a final line that has no trailing newline.
  while read -r pattern spec rest || [ -n "$pattern" ]; do
    case "$pattern" in '' | '#'*) continue ;; esac
    re=$(sg_glob_to_regex "$pattern")
    if [[ $ref =~ $re ]]; then
      IFS=',' read -r -a parts <<<"$spec"
      for p in "${parts[@]}"; do
        if [ "$p" = '{principal}' ]; then
          [ -n "${BASH_REMATCH[1]-}" ] || return 1
          printf '%s\n' "${BASH_REMATCH[1]}"
        else
          printf '%s\n' "$p"
        fi
      done
      return 0
    fi
  done <"$bindings"
  return 1
}

# Write the trust files of commit $1 into directory $2. Fails if any is missing.
sg_extract_trust() {
  local commit=$1 dir=$2 f
  for f in allowed_signers bindings admins; do
    git cat-file blob "$commit:$f" >"$dir/$f" 2>/dev/null || return 1
  done
}

# Print "<oid> <status> <principal>" for every commit in revision range $1
# (passed as one or two rev-list arguments), verified against allowed_signers
# file $2. An empty $2 falls back to the server's own signing config.
sg_signatures() {
  local signers=$1
  shift
  if [ -n "$signers" ]; then
    # Trust mode: only keys in the trust ref count. Disable the OpenPGP and
    # X.509 verifiers so the server's own keyrings cannot vouch for a signer.
    git -c gpg.ssh.allowedSignersFile="$signers" -c gpg.program=false -c gpg.x509.program=false \
      log --format='%H %G? %GS' "$@"
  else
    git log --format='%H %G? %GS' "$@"
  fi
}

# Succeed if commit $1 carries an SSH signature (gpgsig or gpgsig-sha256).
sg_ssh_signed() {
  # awk reads to the end of input on purpose. Exiting early would leave
  # `git cat-file` writing to a closed pipe, and under pipefail its SIGPIPE
  # would reject a large but validly signed commit.
  git cat-file commit "$1" |
    awk '
      done { next }
      /^$/ { done = 1; next }
      /^gpgsig(-sha256)? / { ssh = ($2 == "-----BEGIN" && $3 == "SSH"); done = 1 }
      END { exit !ssh }'
}

# Revision arguments for the commits an update adds to a ref's history.
sg_range() {
  local old=$1 new=$2
  if [ "$old" = "$SG_ZERO_OID" ]; then
    printf '%s\n' "$new"
  else
    printf '%s\n' "$old..$new"
  fi
}
