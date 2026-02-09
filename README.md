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
- Checks each model repo for existing open PRs and skips if any are found.
- Uploads a `.eval_results/terminal_bench.yaml` file via `hf upload --create-pr`.
- The YAML follows the Hugging Face [eval results format](https://huggingface.co/docs/hub/en/model-cards#evaluation-results), referencing the `harborframework/terminal-bench` dataset.

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
    # Add new orgs here:
    # "Leaderboard Org Name": "hf-org-slug",
}
```

The key is the org name as it appears on the tbench.ai leaderboard; the value is the HF username/org that owns the official model repo (case-insensitive match).
