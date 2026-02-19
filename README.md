# Harbor Community Evals

Collect [Terminal-Bench](https://www.tbench.ai/leaderboard/terminal-bench/2.0) evaluation scores for open-weight models and open PRs to add the results to their Hugging Face model repos.

## How it works

1. **`collect_scores.py`** scrapes the Terminal-Bench 2.0 leaderboard, filters for the Terminus 2 agent with open-weight models, matches each model to its official Hugging Face repo, and writes `matched-repos.json`.
2. **`open_eval_prs.sh`** reads `matched-repos.json` and opens a pull request on each model repo adding a `.eval_results/terminal_bench.yaml` file with the benchmark score.

### Filtering logic

- Only entries using the **Terminus 2** agent are kept (the standard baseline agent).
- Models from closed-source orgs (**OpenAI, Google, xAI, Anthropic**) are excluded.
- A `MODEL_ORG_LOOKUP` table maps leaderboard org names to HF org slugs (e.g. `"Kimi" -> "moonshotai"`). Models whose org isn't in the lookup are skipped.

## Setup

Requires Python 3.11+, [uv](https://docs.astral.sh/uv/), and the [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/en/guides/cli) (`hf`).

```bash
uv sync
```

Create a `.env` file with your Hugging Face token (used by the PR script):

```bash
echo 'HF_TOKEN="hf_your_token_here"' > .env
```

## Usage

### 1. Collect scores

```bash
uv run python collect_scores.py
```

This fetches the leaderboard live and writes `matched-repos.json`:

```
Rank  Model                 Model Org     HF Repo                                         Acc
-----------------------------------------------------------------------------------------------
41    Kimi K2.5             Kimi          moonshotai/Kimi-K2.5                          43.2%
54    Kimi K2 Thinking      Moonshot AI   moonshotai/Kimi-K2-Thinking                   35.7%
61    GLM 4.7               Z-AI          zai-org/GLM-4.7                               33.4%
65    MiniMax M2            MiniMax       MiniMaxAI/MiniMax-M2                          30.0%
68    MiniMax M2.1          MiniMax       MiniMaxAI/MiniMax-M2.1                        29.2%
70    Kimi K2 Instruct      Moonshot AI   moonshotai/Kimi-K2-Instruct                   27.8%
79    GLM 4.6               Z.ai          zai-org/GLM-4.6                               24.5%
81    Qwen 3 Coder 480B     Alibaba       Qwen/Qwen3-Coder-480B-A35B-Instruct           23.9%
```

### 2. Open PRs on Hugging Face

Preview what would be submitted:

```bash
./open_eval_prs.sh --dry-run
```

Create the PRs for real:

```bash
./open_eval_prs.sh
```

The script:
- Checks each model repo for existing **Terminal-Bench** PRs and skips only those.
- Uploads a `.eval_results/terminal_bench.yaml` file via `hf upload --create-pr`.
- The YAML follows the Hugging Face [eval results format](https://huggingface.co/docs/hub/en/model-cards#evaluation-results), referencing the `harborframework/terminal-bench-2.0` dataset.
- Resolves auth token in this order: `HF_TOKEN` environment variable, then local `.env`.
- Prints a per-run summary (`processed`, `skipped`, `created`, `failed`) at the end.

### 3. Run as a single job entrypoint

For local simulation of the scheduled job:

```bash
DRY_RUN=1 bash jobs/run_terminal_bench_job.sh
```

To create PRs for real:

```bash
bash jobs/run_terminal_bench_job.sh
```

## Deploy to Hugging Face Jobs

This workflow is designed to run as a scheduled HF Job in namespace `burtenshaw`.

### One-off validation job (dry run)

```bash
hf jobs run python:3.11-slim bash -lc '
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends git ca-certificates curl
python -m pip install --no-cache-dir --upgrade pip uv
git clone --depth 1 https://github.com/burtenshaw/harbor-community-evals.git /workspace/harbor-community-evals
cd /workspace/harbor-community-evals
DRY_RUN=1 bash jobs/run_terminal_bench_job.sh
' --namespace burtenshaw --secrets HF_TOKEN --flavor cpu-basic --timeout 45m
```

### Scheduled production job (weekly, Monday 09:00 UTC)

```bash
hf jobs scheduled run '0 9 * * 1' python:3.11-slim bash -lc '
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends git ca-certificates curl
python -m pip install --no-cache-dir --upgrade pip uv
git clone --depth 1 https://github.com/burtenshaw/harbor-community-evals.git /workspace/harbor-community-evals
cd /workspace/harbor-community-evals
bash jobs/run_terminal_bench_job.sh
' --namespace burtenshaw --secrets HF_TOKEN --flavor cpu-basic --timeout 45m --no-concurrency
```

## Operations Runbook

List scheduled jobs:

```bash
hf jobs scheduled ps --namespace burtenshaw
```

Inspect scheduled job config:

```bash
hf jobs scheduled inspect <scheduled_job_id> --namespace burtenshaw
```

List recent job runs:

```bash
hf jobs ps -a --namespace burtenshaw
```

Read run logs:

```bash
hf jobs logs <job_id> --namespace burtenshaw
```

Pause and resume a schedule:

```bash
hf jobs scheduled suspend <scheduled_job_id> --namespace burtenshaw
hf jobs scheduled resume <scheduled_job_id> --namespace burtenshaw
```

### Adding a new model org

If a new open-weight model org appears on the leaderboard, add it to `MODEL_ORG_LOOKUP` in `collect_scores.py`:

```python
MODEL_ORG_LOOKUP = {
    "Kimi": "moonshotai",
    "Moonshot AI": "moonshotai",
    "Z-AI": "zai-org",
    "Z.ai": "zai-org",
    "MiniMax": "minimaxai",
    "Alibaba": "Qwen",
    "DeepSeek": "deepseek-ai",
    # Add new orgs here:
    # "Leaderboard Org Name": "hf-org-slug",
}
```

The key is the org name as it appears on the tbench.ai leaderboard; the value is the HF username/org that owns the official model repo (case-insensitive match).
