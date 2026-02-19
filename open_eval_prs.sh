#!/usr/bin/env bash
# Open PRs with eval results on Hugging Face model repos.
#
# Reads matched-repos.json and creates .eval_results/ PRs on each model repo
# referencing the harborframework/terminal-bench-2.0 dataset.
#
# Usage:
#   ./open_eval_prs.sh           # create PRs
#   ./open_eval_prs.sh --dry-run # preview only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MATCHED_REPOS="$SCRIPT_DIR/matched-repos.json"
DATASET_ID="harborframework/terminal-bench-2.0"
TASK_ID="terminal_bench"
HF_USER="burtenshaw"
DRY_RUN=false
PROCESSED_COUNT=0
SKIPPED_COUNT=0
CREATED_COUNT=0
FAILED_COUNT=0

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

if [[ -z "${HF_TOKEN:-}" && -f "$SCRIPT_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

if [[ -z "${HF_TOKEN:-}" ]]; then
    echo "ERROR: Missing HF token. Set HF_TOKEN or add it to $SCRIPT_DIR/.env" >&2
    exit 1
fi

if [[ ! -f "$MATCHED_REPOS" ]]; then
    echo "ERROR: Missing $MATCHED_REPOS. Run collect_scores.py first." >&2
    exit 1
fi

SOURCE_URL=$(python3 -c "import json; print(json.load(open('$MATCHED_REPOS'))['source'])")
NUM_ENTRIES=$(python3 -c "import json; print(len(json.load(open('$MATCHED_REPOS'))['entries']))")

echo "INFO: Loaded $NUM_ENTRIES entries from $MATCHED_REPOS"
if [[ "$DRY_RUN" == true ]]; then
    echo "INFO: Dry-run mode enabled; PRs will not be created"
fi

for i in $(seq 0 $((NUM_ENTRIES - 1))); do
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    REPO_ID=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['hf_repo_id'])")
    MODEL=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['model'])")
    ACCURACY=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['accuracy'])")
    DATE=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['date'])")
    AGENT=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['agent'])")

    echo "INFO: Processing $REPO_ID ($MODEL)"

    # Check for existing open PRs.
    # Only block if a Terminal-Bench PR already exists; unrelated open PRs should
    # not prevent proposing or creating a new eval-result PR.
    OPEN_PRS=$(curl -s "https://huggingface.co/api/models/$REPO_ID/discussions" \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
prs = [d for d in data.get('discussions', []) if d.get('status') == 'open' and d.get('isPullRequest')]
for pr in prs:
    print(f\"  #{pr['num']}: {pr['title']}\")
" 2>/dev/null || true)

    TERMINAL_BENCH_OPEN_PRS=$(echo "$OPEN_PRS" | grep -Ei "terminal[-_ ]?bench" || true)

    if [[ -n "$TERMINAL_BENCH_OPEN_PRS" ]]; then
        NUM_TB_PRS=$(echo "$TERMINAL_BENCH_OPEN_PRS" | wc -l | tr -d ' ')
        echo "WARNING: Skipping $REPO_ID — $NUM_TB_PRS open Terminal-Bench PR(s) found:"
        echo "$TERMINAL_BENCH_OPEN_PRS"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    if [[ -n "$OPEN_PRS" ]]; then
        NUM_PRS=$(echo "$OPEN_PRS" | wc -l | tr -d ' ')
        echo "INFO: $REPO_ID has $NUM_PRS unrelated open PR(s); continuing:"
        echo "$OPEN_PRS"
    fi

    # Build YAML content
    YAML_CONTENT="- dataset:
    id: $DATASET_ID
    task_id: $TASK_ID
  value: $ACCURACY
  date: '$DATE'
  source:
    url: $SOURCE_URL
    name: Terminal-Bench Leaderboard
    user: $HF_USER
  notes: \"agent: $AGENT\"
"

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo "--- $REPO_ID (.eval_results/${TASK_ID}.yaml) ---"
        echo "$YAML_CONTENT"
        continue
    fi

    # Write YAML to temp file and upload
    TMPDIR=$(mktemp -d)
    echo "$YAML_CONTENT" > "$TMPDIR/${TASK_ID}.yaml"

    echo "INFO: Creating PR on $REPO_ID"
    if ! hf upload "$REPO_ID" "$TMPDIR/${TASK_ID}.yaml" ".eval_results/${TASK_ID}.yaml" \
        --repo-type model --create-pr \
        --commit-message "Add Terminal-Bench evaluation result (${ACCURACY}%)"; then
        echo "ERROR: Failed to create PR on $REPO_ID" >&2
        FAILED_COUNT=$((FAILED_COUNT + 1))
        rm -rf "$TMPDIR"
        continue
    fi

    CREATED_COUNT=$((CREATED_COUNT + 1))

    rm -rf "$TMPDIR"
done

echo
echo "=== Run Summary ==="
echo "processed: $PROCESSED_COUNT"
echo "skipped:   $SKIPPED_COUNT"
echo "created:   $CREATED_COUNT"
echo "failed:    $FAILED_COUNT"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    exit 1
fi
