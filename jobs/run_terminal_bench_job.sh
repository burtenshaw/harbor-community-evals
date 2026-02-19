#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "INFO: Syncing Python environment"
uv sync --frozen

export PATH="$REPO_ROOT/.venv/bin:$PATH"

echo "INFO: Collecting Terminal-Bench scores"
uv run python collect_scores.py

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "INFO: Running PR step in dry-run mode"
    ./open_eval_prs.sh --dry-run
else
    echo "INFO: Running PR step in create mode"
    ./open_eval_prs.sh
fi
