# Git-Stargate

> Forbidden git-fu harnessing a tiny wormhole to run pre/post-receive hooks on custom refs before mirroring to GitHub. Kiss my SaaS! 🌌🔧

Git-Stargate is a lightweight gateway for Git refs that *aren't* normal branches (e.g., `refs/_blog/*`, `refs/kv/*`, `refs/_shiplog/*`). It enforces fast-forward-only updates, requires signed commits, and can mirror accepted updates to your main remote (GitHub, GitLab, etc.). Perfect for ledger-style content, git-native CMS, and append-only logs.

## Features
- **FF-only**: Rejects non-fast-forward pushes on chosen namespaces.
- **Signed-only**: Requires `git verify-commit` to pass for new tips.
- **Mirroring**: Post-receive hook can push accepted refs to an upstream (optionally under `refs/heads/_mirror/...`).
- **Namespace-targeted**: Default `refs/_blog/*`, configurable.
- **Tiny footprint**: Bash hooks; no daemon needed. Works with bare repos over SSH.

## Quick start
```bash
# In your bare gateway repo (or let bootstrap create it)
./scripts/bootstrap.sh /srv/git/stargate.git
# Optionally set upstream for mirroring
GIT_DIR=/srv/git/stargate.git git remote add origin git@github.com:you/yourrepo.git
```

## CLI (planned)
- `git stargate init /path/to/bare`
- `git stargate set-origin <url>`
- `git stargate ns add refs/_blog/*`

## Config (planned)
- Env or `.stargate/config` for namespaces, mirroring target, signed-only toggle, heads-mirroring flag.

## Hooks
- `pre-receive`: FF-only + signed-only for configured namespaces.
- `post-receive`: Mirrors accepted refs to upstream.

## Why not GitHub branch protection?
Branch protection only covers `refs/heads/*`. If your ledger lives under custom refs, Git-Stargate enforces policy before anything hits GitHub. When GitHub visibility is needed, mirror to `refs/heads/_blog/*`.

## Roadmap
- Small Go CLI for nicer UX.
- Tests for hooks (bats or Go integration).
- Configurable namespace list and mirror mappings.
- Optional heads-mirroring switch.

## License
MIT
