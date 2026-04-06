from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path

from directed_graph_common import (
    bool_string,
    ensure_parent_dir,
    read_csv_rows,
    resolve_default_path,
    script_root_for_file,
    true_string,
    write_csv_rows,
    year_int,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D5: build admissible candidate parent sets and the long learning sample.")
    parser.add_argument("--trajectory-panel-path", default="")
    parser.add_argument("--precedence-statistics-path", default="")
    parser.add_argument("--candidate-parent-sets-output-path", default="")
    parser.add_argument("--dependency-learning-sample-output-path", default="")
    return parser.parse_args()


def get_basis_info(precedence_row: dict[str, str]) -> dict[str, object] | None:
    recommended_basis = precedence_row.get("recommended_precedence_basis", "")
    if recommended_basis == "all_equivalent_to_ready":
        return {
            "basis_used": "ready",
            "candidate_parent_status": "admissible_ready_only",
            "n_plus_basis": int(precedence_row["n_plus_ready"]),
            "n_minus_basis": int(precedence_row["n_minus_ready"]),
            "n_zero_basis": int(precedence_row["n_zero_ready"]),
            "n_observed_basis": int(precedence_row["n_observed_ready"]),
            "precedence_score_basis": precedence_row["precedence_score_ready"],
        }
    if recommended_basis == "prefer_ready":
        return {
            "basis_used": "ready",
            "candidate_parent_status": "admissible_ready_preferred",
            "n_plus_basis": int(precedence_row["n_plus_ready"]),
            "n_minus_basis": int(precedence_row["n_minus_ready"]),
            "n_zero_basis": int(precedence_row["n_zero_ready"]),
            "n_observed_basis": int(precedence_row["n_observed_ready"]),
            "precedence_score_basis": precedence_row["precedence_score_ready"],
        }
    if recommended_basis == "all_only_provisional":
        return {
            "basis_used": "all",
            "candidate_parent_status": "admissible_provisional_only",
            "n_plus_basis": int(precedence_row["n_plus_all"]),
            "n_minus_basis": int(precedence_row["n_minus_all"]),
            "n_zero_basis": int(precedence_row["n_zero_all"]),
            "n_observed_basis": int(precedence_row["n_observed_all"]),
            "precedence_score_basis": precedence_row["precedence_score_all"],
        }
    return None


def write_learning_sample(
    output_path: Path,
    candidate_parents_by_child: dict[str, list[dict[str, object]]],
    trajectory_metadata_by_unit: dict[str, dict[str, object]],
    first_appearance_by_trajectory_skill: dict[tuple[str, str], dict[str, object]],
) -> int:
    fieldnames = [
        "learning_sample_row_id",
        "trajectory_unit",
        "programme",
        "edu_type",
        "trajectory_min_year",
        "trajectory_max_year",
        "representation_family",
        "risk_year",
        "next_year",
        "child_harmonized_skill_id",
        "child_harmonized_name",
        "child_first_year_in_trajectory",
        "child_first_appearance_status",
        "child_event_in_next_year",
        "parent_harmonized_skill_id",
        "parent_harmonized_name",
        "parent_first_year_in_trajectory",
        "parent_observed_by_risk_year",
        "precedence_basis_used",
        "candidate_parent_status",
        "trajectory_branch_resolution_required",
    ]

    ensure_parent_dir(output_path)
    row_count = 0
    sample_row_index = 1

    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()

        for child_skill_id in sorted(candidate_parents_by_child):
            candidate_parents = sorted(
                candidate_parents_by_child[child_skill_id],
                key=lambda row: str(row["parent_harmonized_skill_id"]),
            )
            child_name = str(candidate_parents[0]["child_harmonized_name"])

            for trajectory_unit in sorted(trajectory_metadata_by_unit):
                trajectory_metadata = trajectory_metadata_by_unit[trajectory_unit]
                years = list(trajectory_metadata["years"])
                if len(years) < 2:
                    continue

                child_appearance = first_appearance_by_trajectory_skill.get((trajectory_unit, child_skill_id))
                child_first_year = None if child_appearance is None else int(child_appearance["first_year"])

                if child_appearance is None:
                    child_first_appearance_status = "never_observed_in_trajectory"
                elif child_first_year == int(trajectory_metadata["min_year"]):
                    child_first_appearance_status = "left_censored_first_year"
                else:
                    child_first_appearance_status = "event_observable"

                for year_index in range(len(years) - 1):
                    risk_year = int(years[year_index])
                    next_year = int(years[year_index + 1])

                    if child_appearance is not None and child_first_year is not None and child_first_year <= risk_year:
                        continue

                    child_event_in_next_year = child_appearance is not None and child_first_year == next_year

                    for candidate_parent in candidate_parents:
                        parent_skill_id = str(candidate_parent["parent_harmonized_skill_id"])
                        parent_appearance = first_appearance_by_trajectory_skill.get((trajectory_unit, parent_skill_id))
                        parent_first_year = None if parent_appearance is None else int(parent_appearance["first_year"])
                        parent_observed_by_risk_year = parent_appearance is not None and parent_first_year <= risk_year

                        writer.writerow(
                            {
                                "learning_sample_row_id": f"DLS_{sample_row_index:08d}",
                                "trajectory_unit": trajectory_unit,
                                "programme": trajectory_metadata["programme"],
                                "edu_type": trajectory_metadata["edu_type"],
                                "trajectory_min_year": trajectory_metadata["min_year"],
                                "trajectory_max_year": trajectory_metadata["max_year"],
                                "representation_family": "temporal_only",
                                "risk_year": risk_year,
                                "next_year": next_year,
                                "child_harmonized_skill_id": child_skill_id,
                                "child_harmonized_name": child_name,
                                "child_first_year_in_trajectory": "" if child_first_year is None else child_first_year,
                                "child_first_appearance_status": child_first_appearance_status,
                                "child_event_in_next_year": 1 if child_event_in_next_year else 0,
                                "parent_harmonized_skill_id": parent_skill_id,
                                "parent_harmonized_name": candidate_parent["parent_harmonized_name"],
                                "parent_first_year_in_trajectory": "" if parent_first_year is None else parent_first_year,
                                "parent_observed_by_risk_year": 1 if parent_observed_by_risk_year else 0,
                                "precedence_basis_used": candidate_parent["precedence_basis_used"],
                                "candidate_parent_status": candidate_parent["candidate_parent_status"],
                                "trajectory_branch_resolution_required": bool_string(
                                    bool(trajectory_metadata["branch_resolution_required"])
                                ),
                            }
                        )
                        row_count += 1
                        sample_row_index += 1

    return row_count


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    trajectory_panel_path = resolve_default_path(args.trajectory_panel_path, "../outputs/directed_graph/10_directed_trajectory_panel.csv", script_root)
    precedence_statistics_path = resolve_default_path(args.precedence_statistics_path, "../outputs/directed_graph/13_precedence_statistics.csv", script_root)
    candidate_parent_sets_output_path = resolve_default_path(
        args.candidate_parent_sets_output_path,
        "../outputs/directed_graph/14_candidate_parent_sets.csv",
        script_root,
    )
    dependency_learning_sample_output_path = resolve_default_path(
        args.dependency_learning_sample_output_path,
        "../outputs/directed_graph/14_dependency_learning_sample.csv",
        script_root,
    )

    trajectory_panel_rows = read_csv_rows(trajectory_panel_path)
    if not trajectory_panel_rows:
        raise RuntimeError(f"The directed trajectory panel is empty: {trajectory_panel_path}")

    precedence_rows = read_csv_rows(precedence_statistics_path)
    if not precedence_rows:
        raise RuntimeError(f"The precedence statistics input is empty: {precedence_statistics_path}")

    trajectory_metadata_by_unit: dict[str, dict[str, object]] = {}
    first_appearance_by_trajectory_skill: dict[tuple[str, str], dict[str, object]] = {}

    trajectory_groups: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in trajectory_panel_rows:
        trajectory_groups[row["trajectory_unit"]].append(row)

    for trajectory_unit in sorted(trajectory_groups):
        rows = trajectory_groups[trajectory_unit]
        first_row = rows[0]
        years = sorted({year_int(row["year"]) for row in rows})
        trajectory_metadata_by_unit[trajectory_unit] = {
            "trajectory_unit": trajectory_unit,
            "programme": first_row["programme"],
            "edu_type": first_row["edu_type"],
            "years": years,
            "min_year": years[0],
            "max_year": years[-1],
            "branch_resolution_required": any(true_string(row["requires_branch_resolution"]) for row in rows),
        }

        skill_groups: dict[str, list[dict[str, str]]] = defaultdict(list)
        for row in rows:
            skill_groups[row["harmonized_skill_id"]].append(row)

        for harmonized_skill_id in sorted(skill_groups):
            skill_rows = skill_groups[harmonized_skill_id]
            first_skill_row = skill_rows[0]
            first_year = min(year_int(row["year"]) for row in skill_rows)
            first_appearance_by_trajectory_skill[(trajectory_unit, harmonized_skill_id)] = {
                "trajectory_unit": trajectory_unit,
                "harmonized_skill_id": harmonized_skill_id,
                "harmonized_name": first_skill_row["harmonized_name"],
                "first_year": first_year,
            }

    candidate_parent_rows: list[dict[str, object]] = []
    candidate_parents_by_child: dict[str, list[dict[str, object]]] = defaultdict(list)

    candidate_row_index = 1
    for precedence_row in sorted(
        precedence_rows,
        key=lambda row: (row["target_harmonized_skill_id"], row["source_harmonized_skill_id"]),
    ):
        basis_info = get_basis_info(precedence_row)
        if basis_info is None:
            continue
        if int(basis_info["n_observed_basis"]) <= 0 or int(basis_info["n_plus_basis"]) <= 0:
            continue

        candidate_row = {
            "candidate_parent_row_id": f"CPS_{candidate_row_index:06d}",
            "child_harmonized_skill_id": precedence_row["target_harmonized_skill_id"],
            "child_harmonized_name": precedence_row["target_harmonized_name"],
            "parent_harmonized_skill_id": precedence_row["source_harmonized_skill_id"],
            "parent_harmonized_name": precedence_row["source_harmonized_name"],
            "precedence_basis_used": basis_info["basis_used"],
            "candidate_parent_status": basis_info["candidate_parent_status"],
            "temporal_admissibility_rule": "n_plus_basis_gt_0",
            "n_plus_basis": basis_info["n_plus_basis"],
            "n_minus_basis": basis_info["n_minus_basis"],
            "n_zero_basis": basis_info["n_zero_basis"],
            "n_observed_basis": basis_info["n_observed_basis"],
            "precedence_score_basis": basis_info["precedence_score_basis"],
            "ready_coverage_share": precedence_row["ready_coverage_share"],
            "recommended_precedence_basis": precedence_row["recommended_precedence_basis"],
            "n_support_branch_sensitive": int(precedence_row["n_support_branch_sensitive"]),
            "n_support_nonbranch": int(precedence_row["n_support_nonbranch"]),
        }
        candidate_parent_rows.append(candidate_row)
        candidate_parents_by_child[str(candidate_row["child_harmonized_skill_id"])].append(candidate_row)
        candidate_row_index += 1

    candidate_parent_fieldnames = [
        "candidate_parent_row_id",
        "child_harmonized_skill_id",
        "child_harmonized_name",
        "parent_harmonized_skill_id",
        "parent_harmonized_name",
        "precedence_basis_used",
        "candidate_parent_status",
        "temporal_admissibility_rule",
        "n_plus_basis",
        "n_minus_basis",
        "n_zero_basis",
        "n_observed_basis",
        "precedence_score_basis",
        "ready_coverage_share",
        "recommended_precedence_basis",
        "n_support_branch_sensitive",
        "n_support_nonbranch",
    ]

    write_csv_rows(candidate_parent_sets_output_path, candidate_parent_fieldnames, candidate_parent_rows)
    learning_sample_row_count = write_learning_sample(
        dependency_learning_sample_output_path,
        candidate_parents_by_child,
        trajectory_metadata_by_unit,
        first_appearance_by_trajectory_skill,
    )

    print("Step D5 complete.")
    print(f"Candidate parent edges: {len(candidate_parent_rows)}")
    print(f"Learning sample rows: {learning_sample_row_count}")
    print("Outputs written:")
    print(f" - {candidate_parent_sets_output_path}")
    print(f" - {dependency_learning_sample_output_path}")


if __name__ == "__main__":
    main()
