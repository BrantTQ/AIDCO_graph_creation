from __future__ import annotations

import argparse
from collections import defaultdict

from directed_graph_common import (
    branch_pair_context,
    branch_year_state,
    dominant_relation,
    join_unique_values,
    precedence_score_string,
    read_csv_rows,
    recommended_precedence_basis,
    resolve_default_path,
    script_root_for_file,
    share_string,
    true_string,
    write_csv_rows,
    year_int,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D4: compute first-appearance precedence statistics.")
    parser.add_argument("--trajectory-panel-path", default="")
    parser.add_argument("--trajectory-audit-path", default="")
    parser.add_argument("--within-year-audit-path", default="")
    parser.add_argument("--precedence-statistics-output-path", default="")
    return parser.parse_args()


def new_precedence_accumulator(
    source_skill_id: str,
    target_skill_id: str,
    source_skill_name: str,
    target_skill_name: str,
) -> dict[str, object]:
    return {
        "source_harmonized_skill_id": source_skill_id,
        "target_harmonized_skill_id": target_skill_id,
        "source_harmonized_name": source_skill_name,
        "target_harmonized_name": target_skill_name,
        "n_plus_all": 0,
        "n_minus_all": 0,
        "n_zero_all": 0,
        "n_observed_all": 0,
        "n_plus_ready": 0,
        "n_minus_ready": 0,
        "n_zero_ready": 0,
        "n_observed_ready": 0,
        "n_plus_provisional": 0,
        "n_minus_provisional": 0,
        "n_zero_provisional": 0,
        "n_observed_provisional": 0,
        "n_support_nonbranch": 0,
        "n_support_branch_sensitive": 0,
        "n_support_single_to_single": 0,
        "n_support_single_to_parallel": 0,
        "n_support_parallel_to_single": 0,
        "n_support_parallel_to_parallel": 0,
    }


def update_accumulator(
    accumulator: dict[str, object],
    relation_code: str,
    observation_ready: bool,
    branch_resolution_required: bool,
    branch_pair: str,
) -> None:
    if relation_code == "plus":
        accumulator["n_plus_all"] = int(accumulator["n_plus_all"]) + 1
        key = "n_plus_ready" if observation_ready else "n_plus_provisional"
        accumulator[key] = int(accumulator[key]) + 1
    elif relation_code == "minus":
        accumulator["n_minus_all"] = int(accumulator["n_minus_all"]) + 1
        key = "n_minus_ready" if observation_ready else "n_minus_provisional"
        accumulator[key] = int(accumulator[key]) + 1
    elif relation_code == "zero":
        accumulator["n_zero_all"] = int(accumulator["n_zero_all"]) + 1
        key = "n_zero_ready" if observation_ready else "n_zero_provisional"
        accumulator[key] = int(accumulator[key]) + 1
    else:
        raise RuntimeError(f"Unknown relation code '{relation_code}'.")

    accumulator["n_observed_all"] = int(accumulator["n_observed_all"]) + 1
    observed_key = "n_observed_ready" if observation_ready else "n_observed_provisional"
    accumulator[observed_key] = int(accumulator[observed_key]) + 1

    support_key = "n_support_branch_sensitive" if branch_resolution_required else "n_support_nonbranch"
    accumulator[support_key] = int(accumulator[support_key]) + 1

    if branch_pair == "single_to_single":
        accumulator["n_support_single_to_single"] = int(accumulator["n_support_single_to_single"]) + 1
    elif branch_pair == "single_to_parallel":
        accumulator["n_support_single_to_parallel"] = int(accumulator["n_support_single_to_parallel"]) + 1
    elif branch_pair == "parallel_to_single":
        accumulator["n_support_parallel_to_single"] = int(accumulator["n_support_parallel_to_single"]) + 1
    elif branch_pair == "parallel_to_parallel":
        accumulator["n_support_parallel_to_parallel"] = int(accumulator["n_support_parallel_to_parallel"]) + 1


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    trajectory_panel_path = resolve_default_path(args.trajectory_panel_path, "../outputs/directed_graph/10_directed_trajectory_panel.csv", script_root)
    trajectory_audit_path = resolve_default_path(args.trajectory_audit_path, "../outputs/directed_graph/10_directed_trajectory_audit.csv", script_root)
    within_year_audit_path = resolve_default_path(args.within_year_audit_path, "../outputs/directed_graph/10_within_year_order_audit.csv", script_root)
    precedence_statistics_output_path = resolve_default_path(
        args.precedence_statistics_output_path,
        "../outputs/directed_graph/13_precedence_statistics.csv",
        script_root,
    )

    trajectory_panel_rows = read_csv_rows(trajectory_panel_path)
    if not trajectory_panel_rows:
        raise RuntimeError(f"The directed trajectory panel is empty: {trajectory_panel_path}")

    required_columns = {
        "trajectory_unit",
        "programme",
        "edu_type",
        "year",
        "harmonized_skill_id",
        "harmonized_name",
        "class_id",
        "requires_branch_resolution",
    }
    missing_columns = required_columns.difference(trajectory_panel_rows[0].keys())
    if missing_columns:
        raise RuntimeError(f"The trajectory panel is missing required columns: {', '.join(sorted(missing_columns))}")

    trajectory_audit_rows = read_csv_rows(trajectory_audit_path)
    within_year_audit_rows = read_csv_rows(within_year_audit_path)

    trajectory_audit_by_unit = {
        f"{row['edu_type']}__{row['programme']}": row
        for row in trajectory_audit_rows
        if row.get("audit_level") == "programme_summary"
    }
    within_year_audit_by_key = {
        f"{row['trajectory_unit']}||{year_int(row['year']):02d}": row
        for row in within_year_audit_rows
    }

    skill_rows_by_trajectory: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in trajectory_panel_rows:
        skill_rows_by_trajectory[(row["trajectory_unit"], row["harmonized_skill_id"])].append(row)

    first_appearance_by_trajectory: dict[str, list[dict[str, object]]] = defaultdict(list)

    for trajectory_unit, harmonized_skill_id in sorted(skill_rows_by_trajectory):
        rows = skill_rows_by_trajectory[(trajectory_unit, harmonized_skill_id)]
        first_row = rows[0]
        first_year = min(year_int(row["year"]) for row in rows)
        first_year_rows = [row for row in rows if year_int(row["year"]) == first_year]
        first_year_class_ids = join_unique_values(row["class_id"] for row in first_year_rows)
        first_year_class_count = len({row["class_id"] for row in first_year_rows if row["class_id"].strip()})

        trajectory_audit_row = trajectory_audit_by_unit.get(trajectory_unit)
        if trajectory_audit_row is not None:
            branch_resolution_required = true_string(trajectory_audit_row.get("requires_branch_resolution"))
            branch_resolution_reason = trajectory_audit_row.get("branch_resolution_reason", "")
        else:
            branch_resolution_required = any(true_string(row["requires_branch_resolution"]) for row in rows)
            branch_resolution_reason = ""

        within_year_audit_row = within_year_audit_by_key.get(f"{trajectory_unit}||{first_year:02d}")
        first_year_branch_state = branch_year_state(
            None if within_year_audit_row is None else within_year_audit_row.get("same_year_structure"),
            first_year_class_count,
        )
        first_appearance_readiness = (
            "provisional_parallel_block"
            if branch_resolution_required and first_year_branch_state != "single_class_year"
            else "ready_for_precedence"
        )

        first_appearance_by_trajectory[trajectory_unit].append(
            {
                "trajectory_unit": trajectory_unit,
                "programme": first_row["programme"],
                "edu_type": first_row["edu_type"],
                "harmonized_skill_id": harmonized_skill_id,
                "harmonized_name": first_row["harmonized_name"],
                "first_year": first_year,
                "first_year_class_ids": first_year_class_ids,
                "first_year_class_count": first_year_class_count,
                "first_year_branch_state": first_year_branch_state,
                "first_appearance_readiness": first_appearance_readiness,
                "branch_resolution_required": branch_resolution_required,
                "branch_resolution_reason": branch_resolution_reason,
            }
        )

    pair_accumulators: dict[str, dict[str, object]] = {}

    for trajectory_unit in sorted(first_appearance_by_trajectory):
        first_appearances = sorted(
            first_appearance_by_trajectory[trajectory_unit],
            key=lambda row: (int(row["first_year"]), str(row["harmonized_skill_id"])),
        )

        for left_index, left in enumerate(first_appearances):
            for right in first_appearances[left_index + 1 :]:
                pair_ready = (
                    left["first_appearance_readiness"] == "ready_for_precedence"
                    and right["first_appearance_readiness"] == "ready_for_precedence"
                )
                branch_resolution_required = bool(left["branch_resolution_required"]) or bool(right["branch_resolution_required"])
                branch_pair = branch_pair_context(
                    branch_resolution_required,
                    str(left["first_year_branch_state"]),
                    str(right["first_year_branch_state"]),
                )

                left_to_right_key = f"{left['harmonized_skill_id']}||{right['harmonized_skill_id']}"
                if left_to_right_key not in pair_accumulators:
                    pair_accumulators[left_to_right_key] = new_precedence_accumulator(
                        str(left["harmonized_skill_id"]),
                        str(right["harmonized_skill_id"]),
                        str(left["harmonized_name"]),
                        str(right["harmonized_name"]),
                    )

                right_to_left_key = f"{right['harmonized_skill_id']}||{left['harmonized_skill_id']}"
                if right_to_left_key not in pair_accumulators:
                    pair_accumulators[right_to_left_key] = new_precedence_accumulator(
                        str(right["harmonized_skill_id"]),
                        str(left["harmonized_skill_id"]),
                        str(right["harmonized_name"]),
                        str(left["harmonized_name"]),
                    )

                left_year = int(left["first_year"])
                right_year = int(right["first_year"])
                if left_year < right_year:
                    update_accumulator(pair_accumulators[left_to_right_key], "plus", pair_ready, branch_resolution_required, branch_pair)
                    update_accumulator(pair_accumulators[right_to_left_key], "minus", pair_ready, branch_resolution_required, branch_pair)
                elif left_year > right_year:
                    update_accumulator(pair_accumulators[left_to_right_key], "minus", pair_ready, branch_resolution_required, branch_pair)
                    update_accumulator(pair_accumulators[right_to_left_key], "plus", pair_ready, branch_resolution_required, branch_pair)
                else:
                    update_accumulator(pair_accumulators[left_to_right_key], "zero", pair_ready, branch_resolution_required, branch_pair)
                    update_accumulator(pair_accumulators[right_to_left_key], "zero", pair_ready, branch_resolution_required, branch_pair)

    precedence_rows: list[dict[str, object]] = []
    for pair_key in sorted(pair_accumulators):
        accumulator = pair_accumulators[pair_key]
        observed_all = int(accumulator["n_observed_all"])
        observed_ready = int(accumulator["n_observed_ready"])
        observed_provisional = int(accumulator["n_observed_provisional"])

        precedence_rows.append(
            {
                "source_harmonized_skill_id": accumulator["source_harmonized_skill_id"],
                "target_harmonized_skill_id": accumulator["target_harmonized_skill_id"],
                "source_harmonized_name": accumulator["source_harmonized_name"],
                "target_harmonized_name": accumulator["target_harmonized_name"],
                "n_plus_all": accumulator["n_plus_all"],
                "n_minus_all": accumulator["n_minus_all"],
                "n_zero_all": accumulator["n_zero_all"],
                "n_observed_all": observed_all,
                "precedence_score_all": precedence_score_string(
                    int(accumulator["n_plus_all"]),
                    int(accumulator["n_minus_all"]),
                    int(accumulator["n_zero_all"]),
                ),
                "dominant_relation_all": dominant_relation(
                    int(accumulator["n_plus_all"]),
                    int(accumulator["n_minus_all"]),
                    int(accumulator["n_zero_all"]),
                ),
                "n_plus_ready": accumulator["n_plus_ready"],
                "n_minus_ready": accumulator["n_minus_ready"],
                "n_zero_ready": accumulator["n_zero_ready"],
                "n_observed_ready": observed_ready,
                "precedence_score_ready": precedence_score_string(
                    int(accumulator["n_plus_ready"]),
                    int(accumulator["n_minus_ready"]),
                    int(accumulator["n_zero_ready"]),
                ),
                "dominant_relation_ready": dominant_relation(
                    int(accumulator["n_plus_ready"]),
                    int(accumulator["n_minus_ready"]),
                    int(accumulator["n_zero_ready"]),
                ),
                "n_plus_provisional": accumulator["n_plus_provisional"],
                "n_minus_provisional": accumulator["n_minus_provisional"],
                "n_zero_provisional": accumulator["n_zero_provisional"],
                "n_observed_provisional": observed_provisional,
                "ready_coverage_share": share_string(observed_ready, observed_all),
                "n_support_nonbranch": accumulator["n_support_nonbranch"],
                "n_support_branch_sensitive": accumulator["n_support_branch_sensitive"],
                "n_support_single_to_single": accumulator["n_support_single_to_single"],
                "n_support_single_to_parallel": accumulator["n_support_single_to_parallel"],
                "n_support_parallel_to_single": accumulator["n_support_parallel_to_single"],
                "n_support_parallel_to_parallel": accumulator["n_support_parallel_to_parallel"],
                "recommended_precedence_basis": recommended_precedence_basis(
                    observed_all,
                    observed_ready,
                    observed_provisional,
                ),
            }
        )

    fieldnames = [
        "source_harmonized_skill_id",
        "target_harmonized_skill_id",
        "source_harmonized_name",
        "target_harmonized_name",
        "n_plus_all",
        "n_minus_all",
        "n_zero_all",
        "n_observed_all",
        "precedence_score_all",
        "dominant_relation_all",
        "n_plus_ready",
        "n_minus_ready",
        "n_zero_ready",
        "n_observed_ready",
        "precedence_score_ready",
        "dominant_relation_ready",
        "n_plus_provisional",
        "n_minus_provisional",
        "n_zero_provisional",
        "n_observed_provisional",
        "ready_coverage_share",
        "n_support_nonbranch",
        "n_support_branch_sensitive",
        "n_support_single_to_single",
        "n_support_single_to_parallel",
        "n_support_parallel_to_single",
        "n_support_parallel_to_parallel",
        "recommended_precedence_basis",
    ]

    write_csv_rows(precedence_statistics_output_path, fieldnames, precedence_rows)

    print("Step D4 complete.")
    print(f"First-appearance trajectories analyzed: {len(first_appearance_by_trajectory)}")
    print(f"Ordered skill-pair precedence rows: {len(precedence_rows)}")
    print("Output written:")
    print(f" - {precedence_statistics_output_path}")


if __name__ == "__main__":
    main()
