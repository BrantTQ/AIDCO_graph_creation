from __future__ import annotations

import argparse
from collections import defaultdict

from directed_graph_common import (
    bool_string,
    join_unique_values,
    read_csv_rows,
    resolve_default_path,
    script_root_for_file,
    write_csv_rows,
    year_int,
    year_section_map,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D1: build the directed trajectory panel.")
    parser.add_argument("--harmonized-skills-path", default="")
    parser.add_argument("--trajectory-panel-output-path", default="")
    parser.add_argument("--trajectory-audit-output-path", default="")
    parser.add_argument("--within-year-order-audit-output-path", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    harmonized_skills_path = resolve_default_path(args.harmonized_skills_path, "../data_processed/04_skills_harmonized.csv", script_root)
    trajectory_panel_output_path = resolve_default_path(args.trajectory_panel_output_path, "../outputs/directed_graph/10_directed_trajectory_panel.csv", script_root)
    trajectory_audit_output_path = resolve_default_path(args.trajectory_audit_output_path, "../outputs/directed_graph/10_directed_trajectory_audit.csv", script_root)
    within_year_order_audit_output_path = resolve_default_path(args.within_year_order_audit_output_path, "../outputs/directed_graph/10_within_year_order_audit.csv", script_root)

    rows = read_csv_rows(harmonized_skills_path)
    if not rows:
        raise RuntimeError(f"The harmonized skills input is empty: {harmonized_skills_path}")

    required_columns = {
        "occurrence_id",
        "harmonized_skill_id",
        "harmonized_name",
        "programme",
        "section",
        "year",
        "edu_type",
    }
    missing_columns = required_columns.difference(rows[0].keys())
    if missing_columns:
        raise RuntimeError(f"The harmonized skills input is missing required columns: {', '.join(sorted(missing_columns))}")

    candidate_within_year_fields = [
        "within_year_position",
        "within_year_order",
        "within_year_index",
        "position",
        "sequence",
        "lesson_order",
    ]
    present_within_year_fields = [field for field in candidate_within_year_fields if field in rows[0]]
    within_year_order_available = False
    within_year_order_field = ""
    if present_within_year_fields:
        within_year_order_reason = (
            f"Candidate within-year fields exist ({', '.join(present_within_year_fields)}), "
            "but none is validated for curricular order in the directed branch."
        )
    else:
        within_year_order_reason = (
            "No validated within-year order field exists in 04_skills_harmonized.csv; "
            "section is retained only as a class proxy."
        )

    rows_sorted = sorted(
        rows,
        key=lambda row: (
            row["edu_type"],
            row["programme"],
            year_int(row["year"]),
            row["section"],
            row["harmonized_skill_id"],
            row["occurrence_id"],
        ),
    )

    trajectory_scope_groups: dict[str, list[dict[str, str]]] = defaultdict(list)
    global_years: set[int] = set()
    global_sections: set[str] = set()
    for row in rows_sorted:
        scope_id = f"{row['edu_type']}__{row['programme']}"
        trajectory_scope_groups[scope_id].append(row)
        global_years.add(year_int(row["year"]))
        if row["section"].strip():
            global_sections.add(row["section"].strip())

    trajectory_scope_summaries: dict[str, dict[str, object]] = {}
    trajectory_scope_year_summaries: dict[tuple[str, int], dict[str, object]] = {}

    for scope_id in sorted(trajectory_scope_groups):
        scope_rows = trajectory_scope_groups[scope_id]
        first_row = scope_rows[0]
        programme = first_row["programme"]
        edu_type = first_row["edu_type"]

        years_to_rows: dict[int, list[dict[str, str]]] = defaultdict(list)
        for row in scope_rows:
            years_to_rows[year_int(row["year"])].append(row)

        all_sections = sorted({row["section"] for row in scope_rows if row["section"].strip()})
        max_sections_in_any_year = 0
        programme_years_with_parallel_sections = 0

        for value_year in sorted(years_to_rows):
            year_rows = years_to_rows[value_year]
            sections_this_year = sorted({row["section"] for row in year_rows if row["section"].strip()})
            max_sections_in_any_year = max(max_sections_in_any_year, len(sections_this_year))
            if len(sections_this_year) > 1:
                programme_years_with_parallel_sections += 1

            trajectory_scope_year_summaries[(scope_id, value_year)] = {
                "trajectory_scope_id": scope_id,
                "programme": programme,
                "year": value_year,
                "edu_type": edu_type,
                "n_occurrences": len(year_rows),
                "n_unique_skills": len({row["harmonized_skill_id"] for row in year_rows}),
                "observed_sections": " | ".join(sections_this_year),
                "n_sections_in_year": len(sections_this_year),
                "same_year_parallel_sections_detected": len(sections_this_year) > 1,
            }

        has_parallel_sections_within_year = programme_years_with_parallel_sections > 0
        if has_parallel_sections_within_year:
            section_path_status = "parallel_sections_detected"
        elif len(all_sections) > 1:
            section_path_status = "section_changes_by_year_only"
        else:
            section_path_status = "single_section_path"

        trajectory_scope_summaries[scope_id] = {
            "trajectory_scope_id": scope_id,
            "programme": programme,
            "edu_type": edu_type,
            "n_occurrences": len(scope_rows),
            "n_unique_skills": len({row["harmonized_skill_id"] for row in scope_rows}),
            "n_years": len(years_to_rows),
            "n_sections_total": len(all_sections),
            "max_sections_in_any_year": max_sections_in_any_year,
            "year_section_map": year_section_map(scope_rows),
            "default_rule_evaluation": "programme_x_section_candidate" if has_parallel_sections_within_year else "programme",
            "implemented_trajectory_rule": "edu_type_x_programme",
            "section_path_status": section_path_status,
            "requires_branch_resolution": has_parallel_sections_within_year,
            "branch_resolution_reason": (
                "Same programme has multiple sections in the same year, so section alone does not yet reconstruct one complete end-to-end path."
                if has_parallel_sections_within_year
                else ""
            ),
        }

    panel_rows: list[dict[str, object]] = []
    for index, row in enumerate(rows_sorted, start=1):
        scope_id = f"{row['edu_type']}__{row['programme']}"
        summary = trajectory_scope_summaries[scope_id]
        year_value = year_int(row["year"])
        year_summary = trajectory_scope_year_summaries[(scope_id, year_value)]
        assignment_status = (
            "assigned_provisional_branch_review_needed"
            if summary["requires_branch_resolution"]
            else "assigned"
        )

        panel_rows.append(
            {
                "trajectory_panel_row_id": f"DTR_{index:06d}",
                "occurrence_id": row["occurrence_id"],
                "harmonized_skill_id": row["harmonized_skill_id"],
                "harmonized_name": row["harmonized_name"],
                "programme": row["programme"],
                "section": row["section"],
                "edu_type": row["edu_type"],
                "year": year_value,
                "class_id": row["section"],
                "class_id_source": "section_proxy",
                "within_year_position": "",
                "within_year_position_available": bool_string(within_year_order_available),
                "within_year_order_field": within_year_order_field,
                "within_year_order_reason": within_year_order_reason,
                "time_order_basis": "year_only",
                "time_slice_id": f"year_{year_value:02d}",
                "trajectory_unit": scope_id,
                "default_rule_evaluation": summary["default_rule_evaluation"],
                "implemented_trajectory_rule": summary["implemented_trajectory_rule"],
                "trajectory_assignment_status": assignment_status,
                "section_path_status": summary["section_path_status"],
                "requires_branch_resolution": bool_string(bool(summary["requires_branch_resolution"])),
                "branch_resolution_reason": summary["branch_resolution_reason"],
                "section_count_in_programme_year": year_summary["n_sections_in_year"],
                "same_year_parallel_sections_detected": bool_string(bool(year_summary["same_year_parallel_sections_detected"])),
            }
        )

    global_programmes_with_parallel_sections = sum(
        1 for summary in trajectory_scope_summaries.values() if summary["requires_branch_resolution"]
    )
    global_programme_years_with_parallel_sections = sum(
        1
        for summary in trajectory_scope_year_summaries.values()
        if summary["same_year_parallel_sections_detected"]
    )

    trajectory_audit_rows: list[dict[str, object]] = [
        {
            "audit_level": "global_summary",
            "programme": "",
            "year": "",
            "edu_type": "",
            "n_occurrences": len(rows),
            "n_unique_skills": len({row["harmonized_skill_id"] for row in rows}),
            "n_programmes": len(trajectory_scope_summaries),
            "n_years": len(global_years),
            "n_sections_total": len(global_sections),
            "n_sections_in_year": "",
            "max_sections_in_any_year": max(summary["max_sections_in_any_year"] for summary in trajectory_scope_summaries.values()),
            "section_year_map": "",
            "default_rule_evaluation": "mixed",
            "implemented_trajectory_rule": "edu_type_x_programme",
            "section_path_status": "track_scoped_programme_panel_with_section_proxy",
            "requires_branch_resolution": bool_string(global_programmes_with_parallel_sections > 0),
            "branch_resolution_reason": (
                f"{global_programmes_with_parallel_sections} track-scoped programme trajectory unit(s) contain parallel sections within the same year and need branch-specific resolution before deeper directed modeling."
                if global_programmes_with_parallel_sections > 0
                else ""
            ),
            "class_id_source": "section_proxy",
            "within_year_order_available": bool_string(within_year_order_available),
            "within_year_order_reason": within_year_order_reason,
            "note": f"{global_programme_years_with_parallel_sections} programme-year block(s) contain multiple same-year sections.",
        }
    ]

    for scope_id in sorted(trajectory_scope_summaries):
        summary = trajectory_scope_summaries[scope_id]
        trajectory_audit_rows.append(
            {
                "audit_level": "programme_summary",
                "programme": summary["programme"],
                "year": "",
                "edu_type": summary["edu_type"],
                "n_occurrences": summary["n_occurrences"],
                "n_unique_skills": summary["n_unique_skills"],
                "n_programmes": "",
                "n_years": summary["n_years"],
                "n_sections_total": summary["n_sections_total"],
                "n_sections_in_year": "",
                "max_sections_in_any_year": summary["max_sections_in_any_year"],
                "section_year_map": summary["year_section_map"],
                "default_rule_evaluation": summary["default_rule_evaluation"],
                "implemented_trajectory_rule": summary["implemented_trajectory_rule"],
                "section_path_status": summary["section_path_status"],
                "requires_branch_resolution": bool_string(bool(summary["requires_branch_resolution"])),
                "branch_resolution_reason": summary["branch_resolution_reason"],
                "class_id_source": "section_proxy",
                "within_year_order_available": bool_string(within_year_order_available),
                "within_year_order_reason": within_year_order_reason,
                "note": "",
            }
        )

    for scope_id, value_year in sorted(trajectory_scope_year_summaries):
        year_summary = trajectory_scope_year_summaries[(scope_id, value_year)]
        summary = trajectory_scope_summaries[scope_id]
        trajectory_audit_rows.append(
            {
                "audit_level": "programme_year_summary",
                "programme": year_summary["programme"],
                "year": value_year,
                "edu_type": year_summary["edu_type"],
                "n_occurrences": year_summary["n_occurrences"],
                "n_unique_skills": year_summary["n_unique_skills"],
                "n_programmes": "",
                "n_years": "",
                "n_sections_total": summary["n_sections_total"],
                "n_sections_in_year": year_summary["n_sections_in_year"],
                "max_sections_in_any_year": summary["max_sections_in_any_year"],
                "section_year_map": year_summary["observed_sections"],
                "default_rule_evaluation": summary["default_rule_evaluation"],
                "implemented_trajectory_rule": summary["implemented_trajectory_rule"],
                "section_path_status": (
                    "parallel_sections_detected"
                    if year_summary["same_year_parallel_sections_detected"]
                    else "single_section_observed"
                ),
                "requires_branch_resolution": bool_string(bool(summary["requires_branch_resolution"])),
                "branch_resolution_reason": summary["branch_resolution_reason"],
                "class_id_source": "section_proxy",
                "within_year_order_available": bool_string(within_year_order_available),
                "within_year_order_reason": within_year_order_reason,
                "note": "",
            }
        )

    panel_rows_by_trajectory_year: dict[tuple[str, int], list[dict[str, object]]] = defaultdict(list)
    for row in panel_rows:
        panel_rows_by_trajectory_year[(str(row["trajectory_unit"]), int(row["year"]))].append(row)

    within_year_audit_rows: list[dict[str, object]] = []
    for trajectory_unit, value_year in sorted(panel_rows_by_trajectory_year):
        group_rows = panel_rows_by_trajectory_year[(trajectory_unit, value_year)]
        class_ids = sorted({str(row["class_id"]) for row in group_rows if str(row["class_id"]).strip()})
        within_year_audit_rows.append(
            {
                "trajectory_unit": trajectory_unit,
                "programme": group_rows[0]["programme"],
                "year": value_year,
                "n_occurrences": len(group_rows),
                "n_unique_skills": len({str(row["harmonized_skill_id"]) for row in group_rows}),
                "observed_class_ids": " | ".join(class_ids),
                "n_class_ids": len(class_ids),
                "within_year_order_available": bool_string(within_year_order_available),
                "validated_order_field": within_year_order_field,
                "same_year_structure": "multiple_classes_same_year" if len(class_ids) > 1 else "single_class_only",
                "note": (
                    "Same-year different-class pairs exist, but no validated within-year order is available."
                    if len(class_ids) > 1
                    else "All rows in this trajectory-year block share the same observed class proxy."
                ),
            }
        )

    panel_fieldnames = [
        "trajectory_panel_row_id",
        "occurrence_id",
        "harmonized_skill_id",
        "harmonized_name",
        "programme",
        "section",
        "edu_type",
        "year",
        "class_id",
        "class_id_source",
        "within_year_position",
        "within_year_position_available",
        "within_year_order_field",
        "within_year_order_reason",
        "time_order_basis",
        "time_slice_id",
        "trajectory_unit",
        "default_rule_evaluation",
        "implemented_trajectory_rule",
        "trajectory_assignment_status",
        "section_path_status",
        "requires_branch_resolution",
        "branch_resolution_reason",
        "section_count_in_programme_year",
        "same_year_parallel_sections_detected",
    ]
    audit_fieldnames = [
        "audit_level",
        "programme",
        "year",
        "edu_type",
        "n_occurrences",
        "n_unique_skills",
        "n_programmes",
        "n_years",
        "n_sections_total",
        "n_sections_in_year",
        "max_sections_in_any_year",
        "section_year_map",
        "default_rule_evaluation",
        "implemented_trajectory_rule",
        "section_path_status",
        "requires_branch_resolution",
        "branch_resolution_reason",
        "class_id_source",
        "within_year_order_available",
        "within_year_order_reason",
        "note",
    ]
    within_year_fieldnames = [
        "trajectory_unit",
        "programme",
        "year",
        "n_occurrences",
        "n_unique_skills",
        "observed_class_ids",
        "n_class_ids",
        "within_year_order_available",
        "validated_order_field",
        "same_year_structure",
        "note",
    ]

    write_csv_rows(trajectory_panel_output_path, panel_fieldnames, panel_rows)
    write_csv_rows(trajectory_audit_output_path, audit_fieldnames, trajectory_audit_rows)
    write_csv_rows(within_year_order_audit_output_path, within_year_fieldnames, within_year_audit_rows)

    print("Step D1 complete.")
    print(f"Trajectory panel rows: {len(panel_rows)}")
    print(f"Track-scoped programmes audited: {len(trajectory_scope_summaries)}")
    print(f"Programme-year blocks with same-year parallel sections: {global_programme_years_with_parallel_sections}")
    print("Outputs written:")
    print(f" - {trajectory_panel_output_path}")
    print(f" - {trajectory_audit_output_path}")
    print(f" - {within_year_order_audit_output_path}")


if __name__ == "__main__":
    main()
