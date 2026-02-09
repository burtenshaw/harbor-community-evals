"""
End-to-end pipeline:
  1. Fetch the Terminal-Bench leaderboard from tbench.ai
  2. Filter to "Terminus 2" agent, exclude closed-source model orgs
  3. Match remaining models to Hugging Face Hub repo IDs
  4. Write results to matched-repos.json
"""

import json
import logging
import re
from dataclasses import dataclass, field, asdict
from pathlib import Path

import httpx
from huggingface_hub import HfApi

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

OUTPUT_PATH = Path(__file__).parent / "matched-repos.json"

SOURCE_URL = "https://www.tbench.ai/leaderboard/terminal-bench/2.0"

# Orgs whose models are closed-source / not on HF
CLOSED_MODEL_ORGS = {"OpenAI", "Google", "xAI", "Anthropic"}

AGENT_NAME = "Terminus 2"


# ---------------------------------------------------------------------------
# ORG LOOKUP
# ---------------------------------------------------------------------------

MODEL_ORG_LOOKUP = {
    "Kimi": "moonshotai",
    "Moonshot AI": "moonshotai",
    "Z-AI": "zai-org",
    "Z.ai": "zai-org",
    "MiniMax": "minimaxai",
    "Alibaba": "Qwen",
}

# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class HFMatch:
    """A single HF repo match."""

    repo_id: str
    repo_type: str  # "model", "dataset", or "space"
    url: str


@dataclass
class MatchResult:
    """All HF matches for a given model name."""

    model_name: str
    model_org: str
    matches: list[HFMatch] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Step 1: Fetch & parse the leaderboard
# ---------------------------------------------------------------------------


def fetch_leaderboard(url: str = SOURCE_URL) -> list[dict]:
    """
    Fetch the Terminal-Bench leaderboard HTML and parse the results table.

    Returns a list of dicts with keys:
        rank, agent, model, date, agent_org, model_org, accuracy, error_margin
    """
    logger.info("Fetching leaderboard from %s", url)
    resp = httpx.get(url, follow_redirects=True, timeout=30)
    resp.raise_for_status()

    # Extract the <table> block
    table_match = re.search(r"<table.*?>(.*?)</table>", resp.text, re.DOTALL)
    if not table_match:
        raise RuntimeError("Could not find a <table> element on the page")

    table_html = table_match.group(1)
    rows = re.findall(r"<tr[^>]*>(.*?)</tr>", table_html, re.DOTALL)

    results: list[dict] = []
    for row in rows:
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.DOTALL)
        # Strip inner HTML tags and whitespace
        cells = [re.sub(r"<[^>]+>", "", c).strip() for c in cells]

        # Skip header row and empty rows
        if not cells or cells[1:2] == ["Rank"] or not cells[1:2]:
            continue

        # Expected columns: [checkbox], Rank, Agent, Model, Date, Agent Org, Model Org, Accuracy
        try:
            _, rank_str, agent, model, date, agent_org, model_org, accuracy_str = cells
        except ValueError:
            logger.debug("Skipping unparseable row: %s", cells)
            continue

        # Parse accuracy: "75.1%± 2.4" or "60.7%± N/A"
        acc_match = re.match(r"([\d.]+)%±\s*([\d.]+|N/A)", accuracy_str)
        if not acc_match:
            logger.debug("Skipping row with bad accuracy: %r", accuracy_str)
            continue

        accuracy = float(acc_match.group(1))
        error_margin = float(acc_match.group(2)) if acc_match.group(2) != "N/A" else None

        results.append(
            {
                "rank": int(rank_str),
                "agent": agent,
                "model": model,
                "date": date,
                "agent_org": agent_org,
                "model_org": model_org,
                "accuracy": accuracy,
                "error_margin": error_margin,
            }
        )

    logger.info("Parsed %d entries from leaderboard", len(results))
    return results


# ---------------------------------------------------------------------------
# Step 2: Filter
# ---------------------------------------------------------------------------


def filter_entries(results: list[dict]) -> list[dict]:
    """
    Keep only Terminus 2 entries whose model_org is not closed-source
    AND has a known HF org mapping in MODEL_ORG_LOOKUP.
    """
    entries = [
        r
        for r in results
        if r["agent"] == AGENT_NAME
        and r["model_org"] not in CLOSED_MODEL_ORGS
        and r["model_org"] in MODEL_ORG_LOOKUP
    ]

    # Log which orgs were skipped because they had no lookup entry
    all_terminus = [r for r in results if r["agent"] == AGENT_NAME and r["model_org"] not in CLOSED_MODEL_ORGS]
    skipped_orgs = {r["model_org"] for r in all_terminus if r["model_org"] not in MODEL_ORG_LOOKUP}
    if skipped_orgs:
        logger.info("Skipped model_orgs not in MODEL_ORG_LOOKUP: %s", ", ".join(sorted(skipped_orgs)))

    logger.info(
        "Kept %d entries (agent=%r, excluding closed orgs + unmapped orgs) out of %d total",
        len(entries),
        AGENT_NAME,
        len(results),
    )
    return entries


# ---------------------------------------------------------------------------
# Step 3: Match to HF Hub
# ---------------------------------------------------------------------------


def unique_models(entries: list[dict]) -> list[tuple[str, str]]:
    """Return deduplicated (model_name, model_org) pairs."""
    seen: set[tuple[str, str]] = set()
    models: list[tuple[str, str]] = []
    for entry in entries:
        key = (entry["model"], entry["model_org"])
        if key not in seen:
            seen.add(key)
            models.append(key)
    return models


def search_hf_hub(
    api: HfApi,
    model_name: str,
    model_org: str,
    limit: int = 5,
) -> MatchResult | None:
    """
    Search HF Hub models for a given model name, then pick the single repo
    whose owner matches MODEL_ORG_LOOKUP (case-insensitive).

    Returns None if model_org has no lookup entry or no repo matches.
    """
    hf_org = MODEL_ORG_LOOKUP.get(model_org)
    if hf_org is None:
        logger.info("  %r: skipped (no lookup for %r)", model_name, model_org)
        return None

    hf_org_lower = hf_org.lower()
    result = MatchResult(model_name=model_name, model_org=model_org)

    try:
        for m in api.list_models(search=model_name, limit=limit, sort="likes"):
            repo_owner = m.id.split("/")[0].lower()
            if repo_owner == hf_org_lower:
                result.matches.append(
                    HFMatch(
                        repo_id=m.id,
                        repo_type="model",
                        url=f"https://huggingface.co/{m.id}",
                    )
                )
                break  # only take the first match from the correct org
    except Exception as e:
        logger.warning("Model search failed for %r: %s", model_name, e)

    if result.matches:
        logger.info("  %r -> %s", model_name, result.matches[0].repo_id)
    else:
        logger.info("  %r: no repo found under %r", model_name, hf_org)

    return result if result.matches else None


# ---------------------------------------------------------------------------
# Step 4: Build output
# ---------------------------------------------------------------------------


def build_output(
    entries: list[dict],
    match_results: dict[str, MatchResult],
) -> dict:
    """Combine leaderboard entries with their single HF repo match."""
    enriched_entries = []
    for entry in entries:
        mr = match_results.get(entry["model"])
        if mr is None:
            continue  # skip entries with no HF match
        repo = mr.matches[0]
        enriched_entries.append(
            {
                **entry,
                "hf_repo_id": repo.repo_id,
                "hf_url": repo.url,
            }
        )

    return {
        "source": SOURCE_URL,
        "entries": enriched_entries,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    # 1. Fetch & parse
    all_results = fetch_leaderboard()

    # 2. Filter
    entries = filter_entries(all_results)

    # 3. Search HF Hub
    models = unique_models(entries)
    logger.info(
        "Unique open-weight models to search: %s",
        ", ".join(f"{name} ({org})" for name, org in models),
    )

    api = HfApi()
    match_results: dict[str, MatchResult] = {}
    for model_name, model_org in models:
        result = search_hf_hub(api, model_name, model_org)
        if result is not None:
            match_results[model_name] = result

    # 4. Write output
    output = build_output(entries, match_results)

    with open(OUTPUT_PATH, "w") as f:
        json.dump(output, f, indent=2)

    logger.info("Wrote results to %s", OUTPUT_PATH)

    # Print summary
    print(f"\n=== Terminus 2 + Open-Weight Models ===\n")
    print(f"{'Rank':<6}{'Model':<22}{'Model Org':<14}{'HF Repo':<45}{'Acc':>6}")
    print("-" * 95)
    for e in output["entries"]:
        print(
            f"{e['rank']:<6}{e['model']:<22}{e['model_org']:<14}"
            f"{e['hf_repo_id']:<45}{e['accuracy']:>5.1f}%"
        )


if __name__ == "__main__":
    main()
