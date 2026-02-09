#!/usr/bin/env bash
# Open PRs with eval results on Hugging Face model repos.
#
# Reads matched-repos.json and creates .eval_results/ PRs on each model repo
# referencing the harborframework/terminal-bench dataset.
#
# Usage:
#   ./open_eval_prs.sh           # create PRs
#   ./open_eval_prs.sh --dry-run # preview only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MATCHED_REPOS="$SCRIPT_DIR/matched-repos.json"
DATASET_ID="harborframework/terminal-bench"
TASK_ID="terminal_bench"
HF_USER="burtenshaw"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

source "$SCRIPT_DIR/.env"

SOURCE_URL=$(python3 -c "import json; print(json.load(open('$MATCHED_REPOS'))['source'])")
NUM_ENTRIES=$(python3 -c "import json; print(len(json.load(open('$MATCHED_REPOS'))['entries']))")

echo "INFO: Loaded $NUM_ENTRIES entries from $MATCHED_REPOS"

for i in $(seq 0 $((NUM_ENTRIES - 1))); do
    REPO_ID=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['hf_repo_id'])")
    MODEL=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['model'])")
    ACCURACY=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['accuracy'])")
    DATE=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['date'])")
    AGENT=$(python3 -c "import json; e=json.load(open('$MATCHED_REPOS'))['entries'][$i]; print(e['agent'])")

    echo "INFO: Processing $REPO_ID ($MODEL)"

    # Check for existing open PRs
    OPEN_PRS=$(curl -s "https://huggingface.co/api/models/$REPO_ID/discussions" \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
prs = [d for d in data.get('discussions', []) if d.get('status') == 'open' and d.get('isPullRequest')]
for pr in prs:
    print(f\"  #{pr['num']}: {pr['title']}\")
" 2>/dev/null || true)

    if [[ -n "$OPEN_PRS" ]]; then
        NUM_PRS=$(echo "$OPEN_PRS" | wc -l | tr -d ' ')
        echo "WARNING: Skipping $REPO_ID — $NUM_PRS open PR(s) found:"
        echo "$OPEN_PRS"
        continue
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
    hf upload "$REPO_ID" "$TMPDIR/${TASK_ID}.yaml" ".eval_results/${TASK_ID}.yaml" \
        --repo-type model --create-pr \
        --commit-message "Add Terminal-Bench evaluation result (${ACCURACY}%)"

    rm -rf "$TMPDIR"
done
