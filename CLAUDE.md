# CLAUDE.md — Claude Code instructions

See README.md for project overview, setup, and CLI usage.
See CONTRIBUTING.md for PR workflow and linting setup.

## Project Structure
- `ethd` — main CLI wrapper (~1170 lines Bash). `seid` is a symlink to `ethd`.
- `sei.yml` — Docker Compose service definition. Volume `consensus-data` at `/cosmos`.
- `sei/Dockerfile.source` — multi-stage build: Go builder compiles seid, slim runtime (debian:bookworm-slim, non-root `sei` user).
- `sei/docker-entrypoint.sh` — container init (genesis, snapshot, state-sync, config, peers), then `exec seid start`.
- `scripts/check_sync.sh` — compares local vs public RPC block heights. Exit codes: 0=in_sync, 1=syncing, 2=error.
- `default.env` — environment template (source of truth for all variables).

## Build & Validate
```bash
pre-commit run --all-files   # Lint (CI: lint.yml)
./ethd update --debug --non-interactive  # CI: test-update.yml
```

## Code Style
- Shebang: `#!/usr/bin/env bash`. Strict mode: `set -Eeuo pipefail` (entrypoint: `set -euo pipefail`).
- Double-quoted strings (enforced by pre-commit). Shellcheck-clean.
- Private functions: double-underscore prefix (`__env_migrate`, `__docompose`).
- Environment variables: `SCREAMING_SNAKE_CASE`. No dashes in variable names.
- Exit codes in ethd: 0=success, 1=warning, 2=error, 70=bug, 130=user-terminated.

## Critical Rules
- **ENV_VERSION migration:** When adding/renaming/removing variables in `default.env`, increment `ENV_VERSION` (currently `5`). The `__env_migrate()` function in `ethd` handles backup, restore, and renames via `__old_vars`/`__new_vars` arrays. Variable rename history: `SEID_VERSION` → `SEID_TAG`.
- **Pre-commit hooks:** trailing-whitespace, end-of-file-fixer, check-json, check-yaml, double-quote-string-fixer, shellcheck, shebang check, detect-private-key, detect-aws-credentials, forbid-binary, git-dirty.
- **Lock files:** `/tmp/${__lock_file}` prevents concurrent `update` runs.
