from __future__ import annotations

import argparse
import csv
import math
import random
from collections import defaultdict
from dataclasses import dataclass, field

from directed_graph_common import (
    ensure_parent_dir,
    format_decimal,
    resolve_default_path,
    script_root_for_file,
)


@dataclass
class ScoreMetrics:
    has_data: bool = False
    n_total: float = 0.0
    n_events: float = 0.0
    n_parent_active: float = 0.0
    n_parent_inactive: float = 0.0
    event_rate_parent_active: float = 0.0
    event_rate_parent_inactive: float = 0.0
    event_lift: float = 0.0
    log_loss_improvement: float = 0.0
    smoothed_log_odds_ratio: float = 0.0
    n_x1y1: float = 0.0
    n_x1y0: float = 0.0
    n_x0y1: float = 0.0
    n_x0y0: float = 0.0


@dataclass
class EdgeData:
    parent_skill_id: str
    child_skill_id: str
    parent_name: str
    child_name: str
    precedence_basis_used: str
    candidate_parent_status: str
    n_plus_basis: int
    n_minus_basis: int
    n_zero_basis: int
    n_observed_basis: int
    precedence_score_basis: float
    trajectory_counts: dict[int, list[float]] = field(default_factory=dict)
    full_sample_metrics: ScoreMetrics | None = None
    full_sample_selected: bool = False
    bootstrap_selected_count: int = 0
    bootstrap_rank_sum: float = 0.0
    bootstrap_improvement_sum: float = 0.0
    bootstrap_lift_sum: float = 0.0


@dataclass
class ChildSummary:
    child_skill_id: str
    child_name: str
    candidate_parents: int = 0
    learning_sample_rows: int = 0
    positive_long_rows: int = 0
    full_sample_selected: int = 0
    bootstrap_selected_sum: int = 0
    bootstrap_selected_max: int = 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D6: score direct parent candidates in pure Python.")
    parser.add_argument("--candidate-parent-sets-path", default="")
    parser.add_argument("--dependency-learning-sample-path", default="")
    parser.add_argument("--direct-parent-scores-output-path", default="")
    parser.add_argument("--bootstrap-selection-summary-output-path", default="")
    parser.add_argument("--bootstrap-iterations", type=int, default=25)
    parser.add_argument("--max-parents-per-child", type=int, default=5)
    parser.add_argument("--min-improvement", type=float, default=0.0)
    parser.add_argument("--random-seed", type=int, default=20260406)
    return parser.parse_args()


def parse_int(value: str | None) -> int:
    text = (value or "").strip()
    return int(text) if text else 0


def parse_float(value: str | None) -> float:
    text = (value or "").strip()
    return float(text) if text else 0.0


def score_metrics(a: float, b: float, c: float, d: float) -> ScoreMetrics | None:
    n_total = a + b + c + d
    if n_total <= 0.0:
        return None

    n_events = a + c
    n_parent_active = a + b
    n_parent_inactive = c + d
    base_rate = (n_events + 0.5) / (n_total + 1.0)
    p1 = (a + 0.5) / (n_parent_active + 1.0)
    p0 = (c + 0.5) / (n_parent_inactive + 1.0)
    base_loss = -(n_events * math.log(base_rate) + (n_total - n_events) * math.log(1.0 - base_rate))
    conditional_loss = -(a * math.log(p1) + b * math.log(1.0 - p1) + c * math.log(p0) + d * math.log(1.0 - p0))

    return ScoreMetrics(
        has_data=True,
        n_total=n_total,
        n_events=n_events,
        n_parent_active=n_parent_active,
        n_parent_inactive=n_parent_inactive,
        event_rate_parent_active=p1,
        event_rate_parent_inactive=p0,
        event_lift=p1 - p0,
        log_loss_improvement=base_loss - conditional_loss,
        smoothed_log_odds_ratio=math.log(((a + 0.5) * (d + 0.5)) / ((b + 0.5) * (c + 0.5))),
        n_x1y1=a,
        n_x1y0=b,
        n_x0y1=c,
        n_x0y0=d,
    )


def is_selectable(metrics: ScoreMetrics, min_improvement: float) -> bool:
    return metrics.has_data and metrics.log_loss_improvement > min_improvement and metrics.event_lift > 0.0 and metrics.n_x1y1 > 0.0


def metric_value(metrics: ScoreMetrics | None, attribute: str) -> str:
    if metrics is None:
        return "0" if attribute.startswith("n_") else ""

    value = getattr(metrics, attribute)
    if attribute.startswith("n_"):
        return str(int(round(value)))
    return format_decimal(value) if metrics.has_data else ""


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    candidate_parent_sets_path = resolve_default_path(args.candidate_parent_sets_path, "../outputs/directed_graph/14_candidate_parent_sets.csv", script_root)
    dependency_learning_sample_path = resolve_default_path(
        args.dependency_learning_sample_path,
        "../outputs/directed_graph/14_dependency_learning_sample.csv",
        script_root,
    )
    direct_parent_scores_output_path = resolve_default_path(
        args.direct_parent_scores_output_path,
        "../outputs/directed_graph/15_direct_parent_scores.csv",
        script_root,
    )
    bootstrap_selection_summary_output_path = resolve_default_path(
        args.bootstrap_selection_summary_output_path,
        "../outputs/directed_graph/15_bootstrap_selection_summary.csv",
        script_root,
    )

    edge_by_key: dict[str, EdgeData] = {}
    edges_by_child: dict[str, list[EdgeData]] = defaultdict(list)
    child_summaries: dict[str, ChildSummary] = {}
    trajectory_units: list[str] = []
    trajectory_index_by_unit: dict[str, int] = {}
    sample_row_count = 0
    positive_long_row_count = 0

    with candidate_parent_sets_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            child_id = row["child_harmonized_skill_id"]
            child_name = row["child_harmonized_name"]
            parent_id = row["parent_harmonized_skill_id"]
            edge_key = f"{parent_id}||{child_id}"

            edge = EdgeData(
                parent_skill_id=parent_id,
                child_skill_id=child_id,
                parent_name=row["parent_harmonized_name"],
                child_name=child_name,
                precedence_basis_used=row["precedence_basis_used"],
                candidate_parent_status=row["candidate_parent_status"],
                n_plus_basis=parse_int(row.get("n_plus_basis")),
                n_minus_basis=parse_int(row.get("n_minus_basis")),
                n_zero_basis=parse_int(row.get("n_zero_basis")),
                n_observed_basis=parse_int(row.get("n_observed_basis")),
                precedence_score_basis=parse_float(row.get("precedence_score_basis")),
            )
            edge_by_key[edge_key] = edge
            edges_by_child[child_id].append(edge)

            if child_id not in child_summaries:
                child_summaries[child_id] = ChildSummary(child_skill_id=child_id, child_name=child_name)
            child_summaries[child_id].candidate_parents += 1

    with dependency_learning_sample_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            sample_row_count += 1
            child_id = row["child_harmonized_skill_id"]
            parent_id = row["parent_harmonized_skill_id"]
            edge = edge_by_key.get(f"{parent_id}||{child_id}")
            if edge is None:
                continue

            trajectory_unit = row["trajectory_unit"]
            trajectory_index = trajectory_index_by_unit.get(trajectory_unit)
            if trajectory_index is None:
                trajectory_index = len(trajectory_units)
                trajectory_index_by_unit[trajectory_unit] = trajectory_index
                trajectory_units.append(trajectory_unit)

            counts = edge.trajectory_counts.setdefault(trajectory_index, [0.0, 0.0, 0.0, 0.0])
            x = parse_int(row.get("parent_observed_by_risk_year"))
            y = parse_int(row.get("child_event_in_next_year"))
            if y == 1:
                positive_long_row_count += 1

            if x == 1 and y == 1:
                counts[0] += 1.0
            elif x == 1 and y == 0:
                counts[1] += 1.0
            elif x == 0 and y == 1:
                counts[2] += 1.0
            else:
                counts[3] += 1.0

            child_summary = child_summaries[child_id]
            child_summary.learning_sample_rows += 1
            if y == 1:
                child_summary.positive_long_rows += 1

    for child_id in sorted(edges_by_child):
        scored: list[tuple[EdgeData, ScoreMetrics]] = []
        for edge in edges_by_child[child_id]:
            a = b = c = d = 0.0
            for counts in edge.trajectory_counts.values():
                a += counts[0]
                b += counts[1]
                c += counts[2]
                d += counts[3]
            metrics = score_metrics(a, b, c, d)
            edge.full_sample_metrics = metrics
            if metrics is not None and is_selectable(metrics, args.min_improvement):
                scored.append((edge, metrics))

        selected = sorted(
            scored,
            key=lambda item: (
                -item[1].log_loss_improvement,
                -item[1].event_lift,
                -item[0].precedence_score_basis,
                item[0].parent_skill_id,
            ),
        )[: args.max_parents_per_child]

        for edge, _metrics in selected:
            edge.full_sample_selected = True
        child_summaries[child_id].full_sample_selected = len(selected)

    total_selected_across_bootstraps = 0
    max_selected_across_bootstraps = 0

    rng = random.Random(args.random_seed)
    ordered_child_ids = sorted(edges_by_child)

    # Bootstrap on trajectory units to keep the dependence structure at the panel level.
    for _bootstrap in range(args.bootstrap_iterations):
        weights = [0] * len(trajectory_units)
        for _draw in range(len(trajectory_units)):
            weights[rng.randrange(len(trajectory_units))] += 1

        selected_this_bootstrap = 0
        for child_id in ordered_child_ids:
            scored: list[tuple[EdgeData, ScoreMetrics]] = []
            for edge in edges_by_child[child_id]:
                a = b = c = d = 0.0
                for trajectory_index, counts in edge.trajectory_counts.items():
                    weight = weights[trajectory_index]
                    if weight == 0:
                        continue
                    a += weight * counts[0]
                    b += weight * counts[1]
                    c += weight * counts[2]
                    d += weight * counts[3]
                metrics = score_metrics(a, b, c, d)
                if metrics is not None and is_selectable(metrics, args.min_improvement):
                    scored.append((edge, metrics))

            selected = sorted(
                scored,
                key=lambda item: (
                    -item[1].log_loss_improvement,
                    -item[1].event_lift,
                    -item[0].precedence_score_basis,
                    item[0].parent_skill_id,
                ),
            )[: args.max_parents_per_child]

            selected_this_bootstrap += len(selected)
            child_summary = child_summaries[child_id]
            child_summary.bootstrap_selected_sum += len(selected)
            child_summary.bootstrap_selected_max = max(child_summary.bootstrap_selected_max, len(selected))

            for rank, (edge, metrics) in enumerate(selected, start=1):
                edge.bootstrap_selected_count += 1
                edge.bootstrap_rank_sum += rank
                edge.bootstrap_improvement_sum += metrics.log_loss_improvement
                edge.bootstrap_lift_sum += metrics.event_lift

        total_selected_across_bootstraps += selected_this_bootstrap
        max_selected_across_bootstraps = max(max_selected_across_bootstraps, selected_this_bootstrap)

    ensure_parent_dir(direct_parent_scores_output_path)
    with direct_parent_scores_output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "parent_harmonized_skill_id",
                "child_harmonized_skill_id",
                "parent_harmonized_name",
                "child_harmonized_name",
                "representation_family",
                "model_type",
                "precedence_basis_used",
                "candidate_parent_status",
                "n_plus_basis",
                "n_minus_basis",
                "n_zero_basis",
                "n_observed_basis",
                "precedence_score_basis",
                "full_sample_selected",
                "n_total_long_rows",
                "n_positive_long_rows",
                "n_parent_active_rows",
                "n_parent_inactive_rows",
                "n_x1y1",
                "n_x1y0",
                "n_x0y1",
                "n_x0y0",
                "event_rate_parent_active",
                "event_rate_parent_inactive",
                "event_lift",
                "log_loss_improvement",
                "smoothed_log_odds_ratio",
                "bootstrap_iterations",
                "max_parents_per_child",
                "min_improvement",
                "bootstrap_selected_count",
                "bootstrap_selection_frequency",
                "bootstrap_mean_selected_rank",
                "bootstrap_mean_selected_improvement",
                "bootstrap_mean_selected_lift",
            ],
        )
        writer.writeheader()

        for child_id in sorted(edges_by_child):
            for edge in sorted(edges_by_child[child_id], key=lambda item: item.parent_skill_id):
                metrics = edge.full_sample_metrics
                selection_frequency = (
                    edge.bootstrap_selected_count / args.bootstrap_iterations
                    if args.bootstrap_iterations > 0
                    else 0.0
                )
                writer.writerow(
                    {
                        "parent_harmonized_skill_id": edge.parent_skill_id,
                        "child_harmonized_skill_id": edge.child_skill_id,
                        "parent_harmonized_name": edge.parent_name,
                        "child_harmonized_name": edge.child_name,
                        "representation_family": "temporal_only",
                        "model_type": "bootstrap_sparse_conditional_screening",
                        "precedence_basis_used": edge.precedence_basis_used,
                        "candidate_parent_status": edge.candidate_parent_status,
                        "n_plus_basis": edge.n_plus_basis,
                        "n_minus_basis": edge.n_minus_basis,
                        "n_zero_basis": edge.n_zero_basis,
                        "n_observed_basis": edge.n_observed_basis,
                        "precedence_score_basis": format_decimal(edge.precedence_score_basis),
                        "full_sample_selected": "true" if edge.full_sample_selected else "false",
                        "n_total_long_rows": metric_value(metrics, "n_total"),
                        "n_positive_long_rows": metric_value(metrics, "n_events"),
                        "n_parent_active_rows": metric_value(metrics, "n_parent_active"),
                        "n_parent_inactive_rows": metric_value(metrics, "n_parent_inactive"),
                        "n_x1y1": metric_value(metrics, "n_x1y1"),
                        "n_x1y0": metric_value(metrics, "n_x1y0"),
                        "n_x0y1": metric_value(metrics, "n_x0y1"),
                        "n_x0y0": metric_value(metrics, "n_x0y0"),
                        "event_rate_parent_active": "" if metrics is None or not metrics.has_data else format_decimal(metrics.event_rate_parent_active),
                        "event_rate_parent_inactive": "" if metrics is None or not metrics.has_data else format_decimal(metrics.event_rate_parent_inactive),
                        "event_lift": "" if metrics is None or not metrics.has_data else format_decimal(metrics.event_lift),
                        "log_loss_improvement": "" if metrics is None or not metrics.has_data else format_decimal(metrics.log_loss_improvement),
                        "smoothed_log_odds_ratio": "" if metrics is None or not metrics.has_data else format_decimal(metrics.smoothed_log_odds_ratio),
                        "bootstrap_iterations": args.bootstrap_iterations,
                        "max_parents_per_child": args.max_parents_per_child,
                        "min_improvement": format_decimal(args.min_improvement),
                        "bootstrap_selected_count": edge.bootstrap_selected_count,
                        "bootstrap_selection_frequency": format_decimal(selection_frequency),
                        "bootstrap_mean_selected_rank": (
                            ""
                            if edge.bootstrap_selected_count == 0
                            else format_decimal(edge.bootstrap_rank_sum / edge.bootstrap_selected_count)
                        ),
                        "bootstrap_mean_selected_improvement": (
                            ""
                            if edge.bootstrap_selected_count == 0
                            else format_decimal(edge.bootstrap_improvement_sum / edge.bootstrap_selected_count)
                        ),
                        "bootstrap_mean_selected_lift": (
                            ""
                            if edge.bootstrap_selected_count == 0
                            else format_decimal(edge.bootstrap_lift_sum / edge.bootstrap_selected_count)
                        ),
                    }
                )

    ensure_parent_dir(bootstrap_selection_summary_output_path)
    with bootstrap_selection_summary_output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "summary_level",
                "child_harmonized_skill_id",
                "child_harmonized_name",
                "model_type",
                "bootstrap_iterations",
                "max_parents_per_child",
                "min_improvement",
                "n_trajectory_units",
                "n_candidate_edges",
                "n_children",
                "n_learning_sample_rows",
                "n_positive_long_rows",
                "n_full_sample_selected_edges",
                "n_edges_selected_at_least_once",
                "mean_selected_edges_per_bootstrap",
                "max_selected_edges_single_bootstrap",
                "note",
            ],
        )
        writer.writeheader()

        writer.writerow(
            {
                "summary_level": "global",
                "child_harmonized_skill_id": "",
                "child_harmonized_name": "",
                "model_type": "bootstrap_sparse_conditional_screening",
                "bootstrap_iterations": args.bootstrap_iterations,
                "max_parents_per_child": args.max_parents_per_child,
                "min_improvement": format_decimal(args.min_improvement),
                "n_trajectory_units": len(trajectory_units),
                "n_candidate_edges": len(edge_by_key),
                "n_children": len(child_summaries),
                "n_learning_sample_rows": sample_row_count,
                "n_positive_long_rows": positive_long_row_count,
                "n_full_sample_selected_edges": sum(summary.full_sample_selected for summary in child_summaries.values()),
                "n_edges_selected_at_least_once": sum(1 for edge in edge_by_key.values() if edge.bootstrap_selected_count > 0),
                "mean_selected_edges_per_bootstrap": (
                    ""
                    if args.bootstrap_iterations == 0
                    else format_decimal(total_selected_across_bootstraps / args.bootstrap_iterations)
                ),
                "max_selected_edges_single_bootstrap": max_selected_across_bootstraps,
                "note": "Selection uses one-predictor conditional log-loss improvement with bootstrap top-k sparsification per child.",
            }
        )

        for child_id in sorted(child_summaries):
            summary = child_summaries[child_id]
            selected_at_least_once = sum(1 for edge in edges_by_child[child_id] if edge.bootstrap_selected_count > 0)
            writer.writerow(
                {
                    "summary_level": "child",
                    "child_harmonized_skill_id": summary.child_skill_id,
                    "child_harmonized_name": summary.child_name,
                    "model_type": "bootstrap_sparse_conditional_screening",
                    "bootstrap_iterations": args.bootstrap_iterations,
                    "max_parents_per_child": args.max_parents_per_child,
                    "min_improvement": format_decimal(args.min_improvement),
                    "n_trajectory_units": len(trajectory_units),
                    "n_candidate_edges": summary.candidate_parents,
                    "n_children": "",
                    "n_learning_sample_rows": summary.learning_sample_rows,
                    "n_positive_long_rows": summary.positive_long_rows,
                    "n_full_sample_selected_edges": summary.full_sample_selected,
                    "n_edges_selected_at_least_once": selected_at_least_once,
                    "mean_selected_edges_per_bootstrap": (
                        ""
                        if args.bootstrap_iterations == 0
                        else format_decimal(summary.bootstrap_selected_sum / args.bootstrap_iterations)
                    ),
                    "max_selected_edges_single_bootstrap": summary.bootstrap_selected_max,
                    "note": "",
                }
            )

    edges_selected_at_least_once = sum(1 for edge in edge_by_key.values() if edge.bootstrap_selected_count > 0)
    print("Step D6 complete.")
    print(f"Candidate edges scored: {len(edge_by_key)}")
    print(f"Learning sample rows read: {sample_row_count}")
    print(f"Edges selected at least once: {edges_selected_at_least_once}")
    print("Outputs written:")
    print(f" - {direct_parent_scores_output_path}")
    print(f" - {bootstrap_selection_summary_output_path}")


if __name__ == "__main__":
    main()
