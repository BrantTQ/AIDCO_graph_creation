from __future__ import annotations

import argparse
import csv
import math
from collections import defaultdict

from directed_graph_common import (
    bool_string,
    ensure_parent_dir,
    format_decimal,
    parse_float,
    parse_int,
    resolve_default_path,
    script_root_for_file,
    write_csv_rows,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D7: choose the directed graph rule automatically.")
    parser.add_argument("--direct-parent-scores-path", default="")
    parser.add_argument("--dependency-learning-sample-path", default="")
    parser.add_argument("--selection-surface-output-path", default="")
    parser.add_argument("--selected-model-output-path", default="")
    parser.add_argument("--manifest-selection-surface-output-path", default="")
    parser.add_argument("--manifest-selected-model-output-path", default="")
    return parser.parse_args()


def clamp_probability(value: float) -> float:
    return min(max(value, 1e-9), 1.0 - 1e-9)


def log_loss(probability: float, event: int) -> float:
    probability = clamp_probability(probability)
    if event == 1:
        return -math.log(probability)
    return -math.log(1.0 - probability)


def parent_event_rate(
    child_id: str,
    parent_id: str,
    heldout_trajectory: str,
    parent_active_totals_all: dict[tuple[str, str], int],
    parent_active_events_all: dict[tuple[str, str], int],
    parent_active_totals_by_trajectory: dict[tuple[str, str], dict[str, int]],
    parent_active_events_by_trajectory: dict[tuple[str, str], dict[str, int]],
    base_rate: float,
) -> float:
    key = (child_id, parent_id)
    active_total = parent_active_totals_all.get(key, 0) - parent_active_totals_by_trajectory.get(key, {}).get(heldout_trajectory, 0)
    active_events = parent_active_events_all.get(key, 0) - parent_active_events_by_trajectory.get(key, {}).get(heldout_trajectory, 0)
    if active_total <= 0:
        return base_rate
    return (active_events + 0.5) / (active_total + 1.0)


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    direct_parent_scores_path = resolve_default_path(args.direct_parent_scores_path, "../outputs/directed_graph/15_direct_parent_scores.csv", script_root)
    dependency_learning_sample_path = resolve_default_path(
        args.dependency_learning_sample_path,
        "../outputs/directed_graph/14_dependency_learning_sample.csv",
        script_root,
    )
    selection_surface_output_path = resolve_default_path(
        args.selection_surface_output_path,
        "../outputs/directed_graph/16_directed_selection_surface.csv",
        script_root,
    )
    selected_model_output_path = resolve_default_path(
        args.selected_model_output_path,
        "../outputs/directed_graph/16_directed_selected_model.csv",
        script_root,
    )
    manifest_selection_surface_output_path = resolve_default_path(
        args.manifest_selection_surface_output_path,
        "../outputs/directed_graph/16_directed_model_selection_surface.csv",
        script_root,
    )
    manifest_selected_model_output_path = resolve_default_path(
        args.manifest_selected_model_output_path,
        "../outputs/directed_graph/16_directed_cutoff_selection.csv",
        script_root,
    )

    with direct_parent_scores_path.open("r", encoding="utf-8-sig", newline="") as handle:
        direct_parent_score_rows = list(csv.DictReader(handle))
    if not direct_parent_score_rows:
        raise RuntimeError(f"The direct parent scores input is empty: {direct_parent_scores_path}")

    # D7 evaluates threshold candidates on held-out trajectory units. We work at the risk-example
    # level instead of the D5 long format so each child-year event is counted once.
    risk_examples_by_key: dict[tuple[str, str, int, int, str], dict[str, object]] = {}
    with dependency_learning_sample_path.open("r", encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            trajectory_unit = row["trajectory_unit"]
            risk_year = parse_int(row["risk_year"])
            next_year = parse_int(row["next_year"])
            child_id = row["child_harmonized_skill_id"]
            key = (trajectory_unit, row["programme"], risk_year, next_year, child_id)
            risk_example = risk_examples_by_key.setdefault(
                key,
                {
                    "trajectory_unit": trajectory_unit,
                    "programme": row["programme"],
                    "edu_type": row["edu_type"],
                    "risk_year": risk_year,
                    "next_year": next_year,
                    "child_harmonized_skill_id": child_id,
                    "child_harmonized_name": row["child_harmonized_name"],
                    "child_event_in_next_year": parse_int(row["child_event_in_next_year"]),
                    "active_parent_ids": set(),
                },
            )
            if parse_int(row["parent_observed_by_risk_year"]) == 1:
                risk_example["active_parent_ids"].add(row["parent_harmonized_skill_id"])

    risk_examples = sorted(
        risk_examples_by_key.values(),
        key=lambda row: (
            str(row["trajectory_unit"]),
            int(row["risk_year"]),
            str(row["child_harmonized_skill_id"]),
        ),
    )
    if not risk_examples:
        raise RuntimeError(f"The dependency learning sample did not produce any risk examples: {dependency_learning_sample_path}")

    child_totals_all: dict[str, int] = defaultdict(int)
    child_events_all: dict[str, int] = defaultdict(int)
    child_totals_by_trajectory: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    child_events_by_trajectory: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    parent_active_totals_all: dict[tuple[str, str], int] = defaultdict(int)
    parent_active_events_all: dict[tuple[str, str], int] = defaultdict(int)
    parent_active_totals_by_trajectory: dict[tuple[str, str], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    parent_active_events_by_trajectory: dict[tuple[str, str], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    risk_examples_by_trajectory: dict[str, list[dict[str, object]]] = defaultdict(list)

    for risk_example in risk_examples:
        trajectory_unit = str(risk_example["trajectory_unit"])
        child_id = str(risk_example["child_harmonized_skill_id"])
        event = int(risk_example["child_event_in_next_year"])

        child_totals_all[child_id] += 1
        child_events_all[child_id] += event
        child_totals_by_trajectory[child_id][trajectory_unit] += 1
        child_events_by_trajectory[child_id][trajectory_unit] += event
        risk_examples_by_trajectory[trajectory_unit].append(risk_example)

        for parent_id in risk_example["active_parent_ids"]:
            key = (child_id, str(parent_id))
            parent_active_totals_all[key] += 1
            parent_active_events_all[key] += event
            parent_active_totals_by_trajectory[key][trajectory_unit] += 1
            parent_active_events_by_trajectory[key][trajectory_unit] += event

    edges_by_child: dict[str, list[dict[str, object]]] = defaultdict(list)
    threshold_values: set[float] = set()
    representation_family = ""
    model_type = ""

    for row in direct_parent_score_rows:
        child_id = row["child_harmonized_skill_id"]
        q_value = parse_float(row["bootstrap_selection_frequency"])
        threshold_values.add(q_value)
        representation_family = representation_family or row["representation_family"]
        model_type = model_type or row["model_type"]
        edges_by_child[child_id].append(
            {
                "parent_harmonized_skill_id": row["parent_harmonized_skill_id"],
                "parent_harmonized_name": row["parent_harmonized_name"],
                "child_harmonized_name": row["child_harmonized_name"],
                "bootstrap_selection_frequency": q_value,
                "full_sample_selected": row["full_sample_selected"],
                "candidate_parent_status": row["candidate_parent_status"],
                "precedence_basis_used": row["precedence_basis_used"],
            }
        )

    threshold_candidates = sorted(threshold_values)
    trajectories = sorted(risk_examples_by_trajectory)

    selection_surface_rows: list[dict[str, object]] = []
    for threshold_index, threshold_tau in enumerate(threshold_candidates, start=1):
        selected_parents_by_child: dict[str, set[str]] = {}
        selected_edge_count = 0
        children_with_selected_edges = 0

        for child_id in sorted(edges_by_child):
            selected_parent_ids = {
                str(edge["parent_harmonized_skill_id"])
                for edge in edges_by_child[child_id]
                if float(edge["bootstrap_selection_frequency"]) >= threshold_tau
            }
            if selected_parent_ids:
                selected_parents_by_child[child_id] = selected_parent_ids
                selected_edge_count += len(selected_parent_ids)
                children_with_selected_edges += 1

        total_model_log_loss = 0.0
        total_null_log_loss = 0.0
        heldout_risk_rows = 0
        heldout_positive_events = 0

        for heldout_trajectory in trajectories:
            heldout_examples = risk_examples_by_trajectory[heldout_trajectory]
            for risk_example in heldout_examples:
                child_id = str(risk_example["child_harmonized_skill_id"])
                event = int(risk_example["child_event_in_next_year"])
                heldout_risk_rows += 1
                heldout_positive_events += event

                train_total = child_totals_all[child_id] - child_totals_by_trajectory[child_id].get(heldout_trajectory, 0)
                train_events = child_events_all[child_id] - child_events_by_trajectory[child_id].get(heldout_trajectory, 0)
                base_rate = (train_events + 0.5) / (train_total + 1.0) if train_total > 0 else 0.5

                model_probability = base_rate
                active_selected_parents = risk_example["active_parent_ids"].intersection(selected_parents_by_child.get(child_id, set()))
                for parent_id in active_selected_parents:
                    model_probability = max(
                        model_probability,
                        parent_event_rate(
                            child_id,
                            str(parent_id),
                            heldout_trajectory,
                            parent_active_totals_all,
                            parent_active_events_all,
                            parent_active_totals_by_trajectory,
                            parent_active_events_by_trajectory,
                            base_rate,
                        ),
                    )

                total_model_log_loss += log_loss(model_probability, event)
                total_null_log_loss += log_loss(base_rate, event)

        log_loss_improvement = total_null_log_loss - total_model_log_loss
        selection_surface_rows.append(
            {
                "selection_candidate_id": f"DSF_{threshold_index:03d}",
                "representation_family": representation_family or "temporal_only",
                "model_type": model_type or "bootstrap_sparse_conditional_screening",
                "evaluation_family": "leave_one_trajectory_out_log_loss",
                "threshold_tau": format_decimal(threshold_tau),
                "global_edge_rule": "bootstrap_selection_frequency_ge_tau",
                "n_selected_global_edges": selected_edge_count,
                "n_selected_children": children_with_selected_edges,
                "mean_selected_parents_per_child": (
                    ""
                    if children_with_selected_edges == 0
                    else format_decimal(selected_edge_count / children_with_selected_edges)
                ),
                "n_trajectory_folds": len(trajectories),
                "heldout_risk_rows": heldout_risk_rows,
                "heldout_positive_events": heldout_positive_events,
                "cv_model_log_loss": format_decimal(total_model_log_loss),
                "cv_null_log_loss": format_decimal(total_null_log_loss),
                "cv_log_loss_improvement": format_decimal(log_loss_improvement),
                "cv_log_loss_improvement_per_row": (
                    ""
                    if heldout_risk_rows == 0
                    else format_decimal(log_loss_improvement / heldout_risk_rows)
                ),
                "thresholded_outperforms_null": bool_string(log_loss_improvement > 0.0),
                "note": "Prediction uses leave-one-trajectory-out evaluation with child-specific smoothed baseline rates and active-parent evidence from selected edges.",
            }
        )

    ranked_surface_rows = sorted(
        selection_surface_rows,
        key=lambda row: (-parse_float(str(row["cv_log_loss_improvement"])), parse_float(str(row["threshold_tau"]))),
    )
    for selection_rank, row in enumerate(ranked_surface_rows, start=1):
        row["selection_rank"] = selection_rank

    best_row = ranked_surface_rows[0]
    best_threshold = parse_float(str(best_row["threshold_tau"]))
    thresholded_outperforms_null = parse_float(str(best_row["cv_log_loss_improvement"])) > 0.0

    if thresholded_outperforms_null:
        selection_mode = "thresholded_binary"
        weighted_edge_rule = ""
        fallback_reason = ""
        selected_edge_count = parse_int(str(best_row["n_selected_global_edges"]))
        selected_child_count = parse_int(str(best_row["n_selected_children"]))
        mean_selected_parents_per_child = str(best_row["mean_selected_parents_per_child"])
    else:
        selection_mode = "weighted_retained"
        weighted_edge_rule = "bootstrap_selection_frequency_gt_zero"
        fallback_reason = "No thresholded graph improved held-out prediction relative to the null child-rate baseline."
        positive_support_edges = [row for row in direct_parent_score_rows if parse_float(row["bootstrap_selection_frequency"]) > 0.0]
        selected_edge_count = len(positive_support_edges)
        selected_child_count = len({row["child_harmonized_skill_id"] for row in positive_support_edges})
        mean_selected_parents_per_child = (
            ""
            if selected_child_count == 0
            else format_decimal(selected_edge_count / selected_child_count)
        )

    selected_model_rows = [
        {
            "selected_model_id": "DSM_001",
            "representation_family": representation_family or "temporal_only",
            "model_type": model_type or "bootstrap_sparse_conditional_screening",
            "selection_mode": selection_mode,
            "threshold_tau": format_decimal(best_threshold) if thresholded_outperforms_null else "",
            "global_edge_rule": "bootstrap_selection_frequency_ge_tau" if thresholded_outperforms_null else "",
            "weighted_edge_rule": weighted_edge_rule,
            "evaluation_family": "leave_one_trajectory_out_log_loss",
            "selected_cv_log_loss_improvement": best_row["cv_log_loss_improvement"],
            "selected_cv_model_log_loss": best_row["cv_model_log_loss"],
            "selected_cv_null_log_loss": best_row["cv_null_log_loss"],
            "n_selected_global_edges": selected_edge_count,
            "n_selected_children": selected_child_count,
            "mean_selected_parents_per_child": mean_selected_parents_per_child,
            "n_trajectory_folds": len(trajectories),
            "heldout_risk_rows": best_row["heldout_risk_rows"],
            "heldout_positive_events": best_row["heldout_positive_events"],
            "null_outperformed_by_threshold": bool_string(thresholded_outperforms_null),
            "fallback_reason": fallback_reason,
            "note": (
                "The thresholded binary rule is used for local DAG instantiation."
                if thresholded_outperforms_null
                else "The weighted directed graph is retained for local instantiation because no thresholded rule beat the null model."
            ),
        }
    ]

    surface_fieldnames = [
        "selection_candidate_id",
        "representation_family",
        "model_type",
        "evaluation_family",
        "threshold_tau",
        "global_edge_rule",
        "n_selected_global_edges",
        "n_selected_children",
        "mean_selected_parents_per_child",
        "n_trajectory_folds",
        "heldout_risk_rows",
        "heldout_positive_events",
        "cv_model_log_loss",
        "cv_null_log_loss",
        "cv_log_loss_improvement",
        "cv_log_loss_improvement_per_row",
        "thresholded_outperforms_null",
        "selection_rank",
        "note",
    ]
    selected_fieldnames = [
        "selected_model_id",
        "representation_family",
        "model_type",
        "selection_mode",
        "threshold_tau",
        "global_edge_rule",
        "weighted_edge_rule",
        "evaluation_family",
        "selected_cv_log_loss_improvement",
        "selected_cv_model_log_loss",
        "selected_cv_null_log_loss",
        "n_selected_global_edges",
        "n_selected_children",
        "mean_selected_parents_per_child",
        "n_trajectory_folds",
        "heldout_risk_rows",
        "heldout_positive_events",
        "null_outperformed_by_threshold",
        "fallback_reason",
        "note",
    ]

    # The manifest and the step file diverge on the exact filenames for D7, so we export both
    # name variants with the same content to keep the branch compatible with both specifications.
    write_csv_rows(selection_surface_output_path, surface_fieldnames, ranked_surface_rows)
    write_csv_rows(selected_model_output_path, selected_fieldnames, selected_model_rows)
    write_csv_rows(manifest_selection_surface_output_path, surface_fieldnames, ranked_surface_rows)
    write_csv_rows(manifest_selected_model_output_path, selected_fieldnames, selected_model_rows)

    print("Step D7 complete.")
    print(f"Thresholds evaluated: {len(ranked_surface_rows)}")
    print(f"Selected model mode: {selection_mode}")
    print("Outputs written:")
    print(f" - {selection_surface_output_path}")
    print(f" - {selected_model_output_path}")
    print(f" - {manifest_selection_surface_output_path}")
    print(f" - {manifest_selected_model_output_path}")


if __name__ == "__main__":
    main()
