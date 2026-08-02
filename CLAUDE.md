# alpine-anywhere: rules for Claude Code

Remote Alpine Linux installer used to provision Warren exit nodes.

> Shared Warren rules (single source of truth: WarrenBrowse/warren-workspace).
> They resolve when this repo is checked out inside the workspace (mani sync);
> cloned standalone, the imports just warn harmlessly.
@../shared/rules/00-conventions.md
@../shared/rules/30-git-commits.md

## Repo-specific rules

- **Non-interactive means non-interactive at every stage, including after the
  pivot.** The installer runs in two phases and the second one lives in the RAM
  installer, so a flag threaded only into the first phase leaves a prompt reading
  `/dev/console` on a box nobody is watching. That is exactly how
  `deploy-exit.sh install --yes` (without `--force`) hung a provisioning run in
  July 2026: `ASSUME_YES` reached the pivot but `confirm_action` honoured only
  `FORCE`. Both are now honoured, `ASSUME_YES` persists into `config.env`, and
  `-y` is threaded into the three `--install-continue` builders in `lib/pivot.sh`.
  Adding a prompt anywhere means checking both flags reach it.
- **Local gates first: `make lint test`** (shellcheck + shellspec `spec/`),
  exactly what CI runs; the throwaway-box validation comes after, never instead.
- **This repo provisions production exits.** A change here is validated on a
  throwaway box before it touches the fleet; the `warren-exit-fleet` skill has the
  procedure.
