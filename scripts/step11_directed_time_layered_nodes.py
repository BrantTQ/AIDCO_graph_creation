from __future__ import annotations

import argparse
from collections import defaultdict

from directed_graph_common import (
    bool_string,
    join_unique_values,
    read_csv_rows,
    resolve_default_path,
    script_root_for_file,
    true_string,
    write_csv_rows,
    year_int,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D2: build time-layered directed nodes.")
    parser.add_argument("--trajectory-panel-path", default="")
    parser.add_argument("--directed-nodes-output-path", default="")
    parser.add_argument("--directed-node-provenance-output-path", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    trajectory_panel_path = resolve_default_path(args.trajectory_panel_path, "../outputs/directed_graph/10_directed_trajectory_panel.csv", script_root)
    directed_nodes_output_path = resolve_default_path(args.directed_nodes_output_path, "../outputs/directed_graph/11_directed_nodes.csv", script_root)
    directed_node_provenance_output_path = resolve_default_path(
        args.directed_node_provenance_output_path,
        "../outputs/directed_graph/11_directed_node_provenance.csv",
        script_root,
    )

    trajectory_panel_rows = read_csv_rows(trajectory_panel_path)
    if not trajectory_panel_rows:
        raise RuntimeError(f"The directed trajectory panel is empty: {trajectory_panel_path}")

    required_columns = {
        "occurrence_id",
        "harmonized_skill_id",
        "harmonized_name",
        "trajectory_unit",
        "programme",
        "edu_type",
        "year",
        "class_id",
        "within_year_position_available",
        "trajectory_assignment_status",
        "section_path_status",
        "requires_branch_resolution",
    }
    missing_columns = required_columns.difference(trajectory_panel_rows[0].keys())
    if missing_columns:
        raise RuntimeError(f"The trajectory panel is missing required columns: {', '.join(sorted(missing_columns))}")

    rows_sorted = sorted(
        trajectory_panel_rows,
        key=lambda row: (
            row["trajectory_unit"],
            year_int(row["year"]),
            row["harmonized_skill_id"],
            row["class_id"],
            row["occurrence_id"],
        ),
    )

    node_groups: dict[tuple[str, int, str], list[dict[str, str]]] = defaultdict(list)
    for row in rows_sorted:
        node_groups[(row["trajectory_unit"], year_int(row["year"]), row["harmonized_skill_id"])].append(row)

    node_rows: list[dict[str, object]] = []
    provenance_rows: list[dict[str, object]] = []

    for node_index, group_key in enumerate(sorted(node_groups), start=1):
        trajectory_unit, year_value, harmonized_skill_id = group_key
        rows = node_groups[group_key]
        first_row = rows[0]

        class_ids = sorted({row["class_id"] for row in rows if row["class_id"].strip()})
        assignment_statuses = join_unique_values(row["trajectory_assignment_status"] for row in rows)
        section_path_statuses = join_unique_values(row["section_path_status"] for row in rows)
        branch_resolution_needed = any(true_string(row["requires_branch_resolution"]) for row in rows)

        if len(class_ids) > 1:
            class_context_type = "multiple_classes_same_year"
        elif len(class_ids) == 1:
            class_context_type = "single_class"
        else:
            class_context_type = "missing_class_proxy"

        node_id = f"DTN_{node_index:06d}"
        node_key = f"{trajectory_unit}||{year_value:02d}||{harmonized_skill_id}"

        node_rows.append(
            {
                "node_id": node_id,
                "node_key": node_key,
                "trajectory_unit": trajectory_unit,
                "programme": first_row["programme"],
                "edu_type": first_row["edu_type"],
                "year": year_value,
                "harmonized_skill_id": harmonized_skill_id,
                "harmonized_name": first_row["harmonized_name"],
                "node_time_model": "year_only",
                "within_year_position_available": first_row["within_year_position_available"],
                "observed_class_ids": " | ".join(class_ids),
                "n_class_ids": len(class_ids),
                "class_context_type": class_context_type,
                "n_occurrences_collapsed": len(rows),
                "n_unique_occurrences": len({row["occurrence_id"] for row in rows}),
                "trajectory_assignment_status": assignment_statuses,
                "section_path_status": section_path_statuses,
                "requires_branch_resolution": bool_string(branch_resolution_needed),
            }
        )

        for row in rows:
            provenance_rows.append(
                {
                    "node_id": node_id,
                    "node_key": f"{row['trajectory_unit']}||{year_int(row['year']):02d}||{row['harmonized_skill_id']}",
                    "occurrence_id": row["occurrence_id"],
                    "trajectory_unit": row["trajectory_unit"],
                    "programme": row["programme"],
                    "edu_type": row["edu_type"],
                    "year": year_int(row["year"]),
                    "class_id": row["class_id"],
                    "harmonized_skill_id": row["harmonized_skill_id"],
                    "harmonized_name": row["harmonized_name"],
                    "trajectory_panel_row_id": row["trajectory_panel_row_id"],
                }
            )

    node_fieldnames = [
        "node_id",
        "node_key",
        "trajectory_unit",
        "programme",
        "edu_type",
        "year",
        "harmonized_skill_id",
        "harmonized_name",
        "node_time_model",
        "within_year_position_available",
        "observed_class_ids",
        "n_class_ids",
        "class_context_type",
        "n_occurrences_collapsed",
        "n_unique_occurrences",
        "trajectory_assignment_status",
        "section_path_status",
        "requires_branch_resolution",
    ]
    provenance_fieldnames = [
        "node_id",
        "node_key",
        "occurrence_id",
        "trajectory_unit",
        "programme",
        "edu_type",
        "year",
        "class_id",
        "harmonized_skill_id",
        "harmonized_name",
        "trajectory_panel_row_id",
    ]

    write_csv_rows(directed_nodes_output_path, node_fieldnames, node_rows)
    write_csv_rows(directed_node_provenance_output_path, provenance_fieldnames, provenance_rows)

    print("Step D2 complete.")
    print(f"Directed nodes written: {len(node_rows)}")
    print(f"Node provenance rows written: {len(provenance_rows)}")
    print("Outputs written:")
    print(f" - {directed_nodes_output_path}")
    print(f" - {directed_node_provenance_output_path}")


if __name__ == "__main__":
    main()
