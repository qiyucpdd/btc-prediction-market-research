"""Reconcile the published monthly aggregates without downloading exchange data."""
import json
from math import isclose
from pathlib import Path

STUDY = Path(__file__).resolve().parent / "six-minute"


def load(name):
    return json.loads((STUDY / name).read_text(encoding="utf-8"))


def check():
    archive = load("snapshot-results.json")
    walk = load("walk-results.json")
    hybrid = load("hybrid-results.json")
    counts = archive["coverage"]
    assert sum(counts.values()) == archive["universe"] == walk["archive_distinct_rounds"]
    assert counts["paired"] == archive["paired"] == hybrid["training_rounds"]
    assert counts["paired"] + counts["no_quote"] + counts["no_two_sided_book"] == archive["chart_valid"]

    months = hybrid["monthly_breakdown"]
    monthly = hybrid["monthly"]
    print(f"Settled archive: {archive['universe']:,} rounds; six-minute priced rounds: {archive['paired']:,}")
    for name, total in monthly["scores"].items():
        scores = [month["scores"][name] for month in months]
        rounds = sum(row["rounds"] for row in scores)
        correct = sum(row["correct"] for row in scores)
        brier = sum(row["rounds"] * row["brier"] for row in scores) / rounds
        assert rounds == total["rounds"] == monthly["rounds"]
        assert correct == total["correct"]
        # The monthly and pooled Brier scores are independently rounded to six decimals.
        assert isclose(brier, total["brier"], abs_tol=1e-6)
        print(f"{name:10} {correct:,}/{rounds:,} correct; Brier {total['brier']:.6f}")

    same_rounds = walk["six_minute_priced_monthly"]
    # The chart-only study fits on all available chart rows. The hybrid study
    # refits its chart comparator on the smaller paired training universe.
    assert monthly["scores"]["chart"]["rounds"] == same_rounds["chart"]["rounds"]
    assert monthly["scores"]["book"] == same_rounds["midpoint"]

    paper = monthly["entries_same_rule"]["hybrid"]
    for field in ("entries", "wins", "days", "gross", "net", "worse_cent"):
        assert isclose(sum(month["entries"][field] for month in months), paper[field], abs_tol=1e-6)
    print(f"Hybrid paper: {paper['wins']} wins / {paper['entries']} entries; net USD {paper['net']:.2f}")


if __name__ == "__main__":
    check()
