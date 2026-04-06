from __future__ import annotations

import csv
import os
from pathlib import Path
from typing import Iterable


try:
    csv.field_size_limit(1024 * 1024 * 1024)
except OverflowError:
    csv.field_size_limit(2**31 - 1)


def resolve_default_path(provided_path: str, fallback_relative_path: str, script_root: Path) -> Path:
    if not provided_path or not provided_path.strip():
        return (script_root / fallback_relative_path).resolve()
    return Path(provided_path).resolve()


def ensure_parent_dir(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def bool_string(value: bool) -> str:
    return "true" if value else "false"


def true_string(value: str | None) -> bool:
    return (value or "").strip().lower() == "true"


def year_int(value: str | int) -> int:
    if value is None:
        raise ValueError("Encountered a blank year value.")
    text = str(value).strip()
    if not text:
        raise ValueError("Encountered a blank year value.")
    return int(text)


def year_key(year_value: int) -> str:
    return f"{year_value:02d}"


def join_unique_values(values: Iterable[str | int | None]) -> str:
    unique_values = sorted({str(value).strip() for value in values if str(value).strip()})
    return " | ".join(unique_values)


def year_section_map(rows: list[dict[str, str]]) -> str:
    by_year: dict[int, list[str]] = {}
    for row in rows:
        by_year.setdefault(year_int(row["year"]), []).append(row["section"])
    segments = []
    for value_year in sorted(by_year):
        segments.append(f"{value_year}:{join_unique_values(by_year[value_year])}")
    return " | ".join(segments)


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        return list(reader)


def stream_csv_rows(path: Path):
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            yield row


def write_csv_rows(path: Path, fieldnames: list[str], rows: Iterable[dict[str, object]]) -> None:
    ensure_parent_dir(path)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def split_class_ids(observed_class_ids: str) -> set[str]:
    if not observed_class_ids or not observed_class_ids.strip():
        return set()
    return {token.strip() for token in observed_class_ids.split("|") if token.strip()}


def join_class_set(values: set[str]) -> str:
    return " | ".join(sorted(values))


def class_relation_detail(source_class_set: set[str], target_class_set: set[str], intersection_set: set[str]) -> str:
    if not source_class_set or not target_class_set:
        return "missing_class_proxy"
    if not intersection_set:
        return "disjoint_class_support"
    if len(source_class_set) == 1 and len(target_class_set) == 1:
        return "exact_same_class"
    if join_class_set(source_class_set) == join_class_set(target_class_set):
        return "identical_multi_class_support"
    return "overlapping_multi_class_support"


def branch_year_state(same_year_structure: str | None, n_class_ids: int) -> str:
    if same_year_structure == "multiple_classes_same_year" or n_class_ids > 1:
        return "parallel_class_block"
    return "single_class_year"


def branch_pair_context(branch_resolution_required: bool, source_branch_year_state: str, target_branch_year_state: str) -> str:
    if not branch_resolution_required:
        return "none"
    if source_branch_year_state == "single_class_year" and target_branch_year_state == "single_class_year":
        return "single_to_single"
    if source_branch_year_state == "single_class_year" and target_branch_year_state == "parallel_class_block":
        return "single_to_parallel"
    if source_branch_year_state == "parallel_class_block" and target_branch_year_state == "single_class_year":
        return "parallel_to_single"
    return "parallel_to_parallel"


def branch_resolution_note(
    branch_resolution_required: bool,
    temporal_relation: str,
    branch_pair_context_value: str,
    base_reason: str,
) -> str:
    if not branch_resolution_required:
        return ""

    prefix = base_reason.strip() or "Trajectory contains unresolved same-year parallel sections."
    if branch_pair_context_value == "single_to_single":
        return f"{prefix} Pair stays inside single-class years, so it remains usable in the provisional candidate set."
    if branch_pair_context_value == "single_to_parallel":
        return f"{prefix} Pair enters a year block with parallel class sections and stays provisional until branch paths are resolved."
    if branch_pair_context_value == "parallel_to_single":
        return f"{prefix} Pair exits a parallel class block and may merge unresolved branch membership."
    if branch_pair_context_value == "parallel_to_parallel":
        if temporal_relation.startswith("same_year_"):
            return f"{prefix} Pair is entirely inside a same-year parallel class block and should be interpreted as branch-sensitive same-time support."
        return f"{prefix} Pair links nodes across unresolved parallel class blocks and stays provisional."
    return prefix


def format_decimal(value: float) -> str:
    return f"{value:.12f}".rstrip("0").rstrip(".")


def precedence_score_string(plus_count: int, minus_count: int, zero_count: int) -> str:
    denominator = plus_count + minus_count + zero_count
    if denominator == 0:
        return ""
    return format_decimal((plus_count - minus_count) / denominator)


def share_string(numerator: int, denominator: int) -> str:
    if denominator == 0:
        return ""
    return format_decimal(numerator / denominator)


def dominant_relation(plus_count: int, minus_count: int, zero_count: int) -> str:
    denominator = plus_count + minus_count + zero_count
    if denominator == 0:
        return ""
    max_count = max(plus_count, minus_count, zero_count)
    winners: list[str] = []
    if plus_count == max_count:
        winners.append("source_before_target")
    if minus_count == max_count:
        winners.append("source_after_target")
    if zero_count == max_count:
        winners.append("same_time")
    return "tie" if len(winners) > 1 else winners[0]


def recommended_precedence_basis(observed_all: int, observed_ready: int, observed_provisional: int) -> str:
    if observed_all == 0:
        return ""
    if observed_provisional == 0:
        return "all_equivalent_to_ready"
    if observed_ready > 0:
        return "prefer_ready"
    return "all_only_provisional"


def parse_int(value: str | None) -> int:
    text = (value or "").strip()
    return int(text) if text else 0


def parse_float(value: str | None) -> float:
    text = (value or "").strip()
    return float(text) if text else 0.0


def script_root_for_file(file_path: str) -> Path:
    return Path(file_path).resolve().parent

