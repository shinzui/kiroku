#!/usr/bin/env python3
"""Check EP-3's SQL promotion gate on a disposable PostgreSQL 18 cluster.

No production SQL is installed. Exit 2 means the prefix prototype is rejected;
exit 0 means the selected check completed; index-layout research completion
does not imply promotion or cumulative observer acceptance.
The index-layout scope changes indexes only inside the disposable research DB.
Retain complete EXPLAIN plans and exact inputs; never overwrite an evidence file.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
COLUMNS = "stream_id, stream_name, stream_version, created_at, deleted_at, truncate_before"
VARIANTS = {
    "nullable": f"SELECT {COLUMNS} FROM streams WHERE stream_id <> 0 "
    "AND ($1::text IS NULL OR stream_name > $1) "
    "AND ($2::text IS NULL OR starts_with(stream_name, $2)) "
    "ORDER BY stream_name LIMIT $3",
    "first_prefix": f"SELECT {COLUMNS} FROM streams WHERE stream_id <> 0 "
    "AND starts_with(stream_name, $2) ORDER BY stream_name LIMIT $3",
    "after_prefix": f"SELECT {COLUMNS} FROM streams WHERE stream_id <> 0 "
    "AND stream_name > $1 AND starts_with(stream_name, $2) "
    "ORDER BY stream_name LIMIT $3",
    # LIKE is diagnostic only: fixtures contain no wildcard characters.
    # It must not replace literal-prefix semantics without escaping.
    "after_like": f"SELECT {COLUMNS} FROM streams WHERE stream_id <> 0 "
    "AND stream_name > $1 AND stream_name LIKE ($2 || '%') "
    "ORDER BY stream_name LIMIT $3",
}
CATEGORY_VARIANTS = {
    name: "WITH RECURSIVE next_category AS (SELECT (SELECT s.category FROM streams s "
    f"WHERE s.stream_id <> 0 {first} ORDER BY s.category LIMIT 1) AS category "
    "UNION ALL SELECT (SELECT s.category FROM streams s WHERE s.stream_id <> 0 "
    "AND s.category > n.category ORDER BY s.category LIMIT 1) "
    "FROM next_category n WHERE n.category IS NOT NULL) "
    "SELECT category FROM next_category WHERE category IS NOT NULL LIMIT $2"
    for name, first in [
        ("category_nullable", "AND ($1::text IS NULL OR s.category > $1)"),
        ("category_first", ""),
        ("category_after", "AND s.category > $1"),
    ]
}


def nodes(plan):
    yield plan
    for child in plan.get("Plans", []):
        yield from nodes(child)


def category_streams_probe(sql, database, evidence, save):
    """Measure category equality without changing indexes or planner settings."""
    queries = {
        "first": ("text,integer", "category = $1", "$2"),
        "after": ("text,text,integer", "category = $1 AND stream_name > $2", "$3"),
        "prefix_first": ("text,text,integer", "category = $1 AND starts_with(stream_name,$2)", "$3"),
        "prefix_after": ("text,text,text,integer",
                         "category = $1 AND stream_name > $2 AND starts_with(stream_name,$3)", "$4"),
    }
    for target_size, noise_size in [(1000, 1000), (1000, 20000), (20000, 20000)]:
        seed = ("SET search_path TO kiroku, pg_catalog;\n"
                f"INSERT INTO streams(stream_name) SELECT 'noise-' || lpad(n::text,6,'0') "
                f"FROM generate_series(1,{noise_size}) n ON CONFLICT DO NOTHING;\n"
                f"INSERT INTO streams(stream_name) SELECT 'orders-' || lpad(n::text,6,'0') "
                f"FROM generate_series(1,{target_size}) n ON CONFLICT DO NOTHING;\n"
                "INSERT INTO streams(stream_name) VALUES ('orders') ON CONFLICT DO NOTHING;\n"
                "ANALYZE streams;")
        sql(seed, database)
        evidence.setdefault("fixtures", []).append({"database": database, "sql": seed})
        # The first two fixtures vary unrelated inventory only; the third varies
        # the selected category. This separates global and within-category work.
        cases = [
            ("first", "'orders',11", None, None),
            ("first", "'missing',11", None, None),
            ("after", f"'orders','orders-{target_size-10:06}',11", f"orders-{target_size-10:06}", None),
            ("after", "'orders','orders-999999',11", "orders-999999", None),
            ("prefix_first", "'orders','ord',11", None, "ord"),
            ("prefix_first", "'orders','orders-00099',11", None, "orders-00099"),
            ("prefix_first", "'orders','absent-',11", None, "absent-"),
            ("prefix_after", "'orders','orders-000995','orders-00099',11", "orders-000995", "orders-00099"),
        ]
        for mode in ["force_generic_plan", "force_custom_plan"]:
            for variant, parameters, cursor, prefix in cases:
                types, where, limit = queries[variant]
                for shape in ["direct", "materialized"]:
                    matching = f"SELECT {COLUMNS} FROM streams WHERE stream_id <> 0 AND {where}"
                    query = (matching + f" ORDER BY stream_name LIMIT {limit}" if shape == "direct" else
                             f"WITH matching AS MATERIALIZED ({matching}) "
                             f"SELECT * FROM matching ORDER BY stream_name LIMIT {limit}")
                    settings = ("SET search_path TO kiroku, pg_catalog;\n"
                                f"SET plan_cache_mode = {mode};\n"
                                "SET statement_timeout = '10s';\n"
                                f"PREPARE probe({types}) AS {query};\n")
                    execute = f"EXECUTE probe({parameters})"
                    transcript = settings + "EXPLAIN (ANALYZE,BUFFERS,COSTS OFF,TIMING OFF,FORMAT JSON) " + execute + ";"
                    plan = json.loads(sql(transcript, database))
                    top = plan[0]["Plan"]
                    scans = [n for n in nodes(top) if n.get("Relation Name") == "streams"]
                    examined = sum((n.get("Actual Rows", 0) + n.get("Rows Removed by Filter", 0)
                                    + n.get("Rows Removed by Index Recheck", 0))
                                   * n.get("Actual Loops", 1) for n in scans)
                    buffers = top.get("Shared Hit Blocks", 0) + top.get("Shared Read Blocks", 0)
                    # Check membership, ordering and exclusive cursors independently
                    # against the exact predicate, outside the timed EXPLAIN statement.
                    actual = sql(settings + execute + ";", database).splitlines()
                    actual_names = [row.split("|")[1] for row in actual]
                    is_missing = parameters.startswith("'missing'")
                    category = "missing" if is_missing else "orders"
                    expected_sql = f"SELECT stream_name FROM kiroku.streams WHERE stream_id <> 0 AND category = '{category}'"
                    if cursor is not None:
                        expected_sql += f" AND stream_name > '{cursor}'"
                    if prefix is not None:
                        expected_sql += f" AND starts_with(stream_name,'{prefix}')"
                    expected = sql(expected_sql + " ORDER BY stream_name LIMIT 11;", database).splitlines()
                    if actual_names != expected:
                        raise RuntimeError("category query failed result equivalence")
                    evidence["cases"].append({
                        "database": database, "target_streams": target_size + 1,
                        "noise_streams": noise_size, "mode": mode, "variant": variant, "shape": shape,
                        "category": category, "cursor": cursor, "prefix": prefix,
                        "sql": transcript, "plan": plan, "rows_examined": examined, "buffers": buffers,
                        "items": actual_names, "correct_results": True,
                        "within_budget": examined <= 64 and buffers <= 64})
                    save()


def sql_text(value):
    return "'" + value.replace("'", "''") + "'"


def prefix_successor(prefix):
    """Codepoint upper bound: diagnostic only, NOT safe for every collation."""
    for position in range(len(prefix) - 1, -1, -1):
        code = ord(prefix[position])
        if code < 0x10FFFF:
            following = code + 1
            if 0xD800 <= following <= 0xDFFF:
                following = 0xE000
            return prefix[:position] + chr(following)
    raise ValueError("this diagnostic requires a finite prefix upper bound")


def fixture_typeid(number):
    """Deterministic valid UUIDv7 TypeID specimen, not an application generator."""
    timestamp = 1700000000000 + number
    payload = (timestamp << 80) | (7 << 76) | (2 << 62) | number
    specimen = uuid.UUID(int=payload)
    assert specimen.version == 7 and specimen.variant == uuid.RFC_4122
    alphabet = "0123456789abcdefghjkmnpqrstvwxyz"
    encoded = "".join(alphabet[(payload >> (5 * position)) & 31]
                      for position in range(25, -1, -1))
    assert int.from_bytes(specimen.bytes[:6], "big") == timestamp
    return "order_" + encoded


def range_streams_probe(sql, database, evidence, save):
    """Try name ranges without assuming codepoint order matches DB collation."""
    evidence.setdefault("collations", {})[database] = sql(
        "SELECT datlocprovider, datcollate, datctype, datlocale "
        "FROM pg_database WHERE datname = current_database();", database).strip()
    # Third fixture varies category size; the fourth adds collation-sensitive
    # neighboring names. Each stage extends the same owned database.
    for stage, target_size, noise_size in [("small", 1000, 1000),
                                           ("more_noise", 1000, 20000),
                                           ("large_category", 20000, 20000),
                                           ("neighbors", 20000, 20000)]:
        names = ["orders", "orders-", "orders-%literal", "orders-_literal",
                 "orders-éclair", "orders-漢字", "$all-x", "orders'quote-x"]
        names += ["orders-" + fixture_typeid(n) for n in range(1, target_size + 1)]
        names += ["noise-" + fixture_typeid(n) for n in range(1, noise_size + 1)]
        if stage == "neighbors":
            # Under ICU these punctuation variants can interleave with orders
            # streams; under C they sit outside the orders- prefix interval.
            names += ["orders." + fixture_typeid(n) for n in range(1, noise_size + 1)]
        seed = ("SET search_path TO kiroku, pg_catalog;\n"
                "INSERT INTO streams(stream_name) SELECT value FROM unnest(ARRAY["
                + ",".join(sql_text(name) for name in names)
                + "]) AS input(value) ON CONFLICT DO NOTHING;\nANALYZE streams;")
        sql(seed, database)
        evidence.setdefault("fixtures", []).append({"database": database, "stage": stage, "sql": seed})
        cases = [
            ("category_first", "orders", None, None),
            ("category_missing", "missing", None, None),
            ("category_after", "orders", "orders-" + fixture_typeid(target_size - 10), None),
            ("category_end", "orders", "orders-漢字", None),
            ("category_bare_cursor", "orders", "orders", None),
            ("category_prefix_sparse", "orders", None, "orders-" + fixture_typeid(995)[:-2]),
            ("category_prefix_percent", "orders", None, "orders-%"),
            ("category_prefix_after", "orders", "orders-" + fixture_typeid(target_size - 10), "orders-"),
            ("prefix_first", None, None, "orders-"),
            ("prefix_after", None, "orders-" + fixture_typeid(target_size - 10), "orders-"),
            ("prefix_sparse", None, None, "orders-" + fixture_typeid(995)[:-2]),
            ("prefix_absent", None, None, "absent-"),
            ("prefix_percent", None, None, "orders-%"),
            ("prefix_underscore", None, None, "orders-_"),
            ("prefix_unicode", None, None, "orders-é"),
            ("prefix_all_application", None, None, "$all-"),
            ("prefix_quote", None, None, "orders'"),
        ]
        for mode in ["force_generic_plan", "force_custom_plan"]:
            for label, category, cursor, prefix in cases:
                seek = " AND stream_name > $4" if cursor is not None else ""
                ranged = (f"SELECT {COLUMNS} FROM streams WHERE stream_id <> 0 "
                          "AND stream_name >= $2 AND stream_name < $3" + seek)
                if category is not None:
                    lower = category + "-"
                    if prefix is not None and prefix.startswith(lower):
                        lower = prefix
                    upper = prefix_successor(lower)
                    prefix_filter = " AND starts_with(stream_name,$6)" if prefix is not None else ""
                    # Category membership also includes the dash-less name.
                    # Limit each branch before sorting/merging at most 12 rows.
                    query = ("WITH candidates AS ((SELECT " + COLUMNS
                             + " FROM streams WHERE stream_id <> 0 AND stream_name = $1 "
                             "AND category = $1" + seek + prefix_filter + " LIMIT 1) UNION ALL ("
                             + ranged + " AND category = $1" + prefix_filter
                             + " ORDER BY stream_name LIMIT $5)) "
                             "SELECT * FROM candidates ORDER BY stream_name LIMIT $5")
                    reference = "category = " + sql_text(category)
                    if prefix is not None:
                        reference += " AND starts_with(stream_name," + sql_text(prefix) + ")"
                    predicate = category
                else:
                    lower, upper = prefix, prefix_successor(prefix)
                    query = ranged + " AND starts_with(stream_name,$1) ORDER BY stream_name LIMIT $5"
                    reference = "starts_with(stream_name," + sql_text(prefix) + ")"
                    predicate = prefix
                parameters = ",".join([sql_text(predicate), sql_text(lower), sql_text(upper),
                                       "NULL" if cursor is None else sql_text(cursor), "11",
                                       "NULL" if prefix is None else sql_text(prefix)])
                shapes = [("category_column" if category is not None else "prefix", query)]
                if category is not None:
                    # Compare a semantically identical name predicate: generic
                    # category stats can prefer the unordered category index.
                    # This is diagnostic SQL, not a planner setting or hint.
                    shapes.append(("name_predicate", query.replace(
                        "category = $1", "split_part(stream_name,'-',1) = $1")))
                for shape, shape_query in shapes:
                    range_streams_case(sql, database, evidence, save, mode, stage, label,
                                       target_size, noise_size, category, cursor, prefix,
                                       lower, upper, shape, shape_query, parameters, reference)


def range_streams_case(sql, database, evidence, save, mode, stage, label,
                       target_size, noise_size, category, cursor, prefix,
                       lower, upper, shape, query, parameters, reference):
    settings = ("SET search_path TO kiroku, pg_catalog;\n"
                f"SET plan_cache_mode = {mode};\nSET statement_timeout = '10s';\n"
                f"PREPARE probe(text,text,text,text,integer,text) AS {query};\n")
    execute = f"EXECUTE probe({parameters});"
    transcript = settings + "EXPLAIN (ANALYZE,BUFFERS,COSTS OFF,TIMING OFF,FORMAT JSON) " + execute
    plan = json.loads(sql(transcript, database))
    top = plan[0]["Plan"]
    scans = [n for n in nodes(top) if n.get("Relation Name") == "streams"]
    examined = sum((n.get("Actual Rows", 0) + n.get("Rows Removed by Filter", 0)
                    + n.get("Rows Removed by Index Recheck", 0))
                   * n.get("Actual Loops", 1) for n in scans)
    buffers = top.get("Shared Hit Blocks", 0) + top.get("Shared Read Blocks", 0)
    actual = [row.split("|")[1] for row in sql(settings + execute, database).splitlines()]
    if cursor is not None:
        reference += " AND stream_name > " + sql_text(cursor)
    expected = sql("SELECT stream_name FROM kiroku.streams WHERE stream_id <> 0 AND "
                   + reference + " ORDER BY stream_name LIMIT 11;", database).splitlines()
    # Retain correctness failures rather than stopping before the
    # other collation/plan cases. Fast, wrong answers cannot pass.
    correct = actual == expected
    evidence["cases"].append({
        "database": database, "stage": stage, "target_typeid_streams": target_size,
        "noise_streams": noise_size, "mode": mode, "variant": label, "shape": shape,
        "category": category, "cursor": cursor, "prefix": prefix,
        "lower": lower, "upper": upper, "sql": transcript, "plan": plan,
        "rows_examined": examined, "buffers": buffers, "items": actual,
        "expected_items": expected, "correct_results": correct,
        "index_conditions": [n.get("Index Cond") for n in nodes(top) if n.get("Index Cond")],
        "within_budget": correct and examined <= 64 and buffers <= 64})
    save()


def index_layout_probe(sql, database, evidence, save):
    """Research replacement footprint/read plans; no timed append workload."""
    evidence["write_cost_measured"] = False
    for size in [1000, 20000]:
        # Restore the control before extending the fixture. Both measured
        # category indexes are freshly built, avoiding a bulk-build advantage.
        sql("DROP INDEX IF EXISTS kiroku.ix_streams_category_name; "
            "CREATE INDEX IF NOT EXISTS ix_streams_category ON kiroku.streams(category);", database)
        names = [category + "-" + fixture_typeid(n)
                 for category in ["orders", "noise"] for n in range(1, size + 1)]
        names += ["orders", "orders-", "orders-%literal", "orders-_literal", "orders-éclair", "orders-漢字"]
        seed = ("INSERT INTO kiroku.streams(stream_name) SELECT value FROM unnest(ARRAY["
                + ",".join(sql_text(name) for name in names)
                + "]) AS input(value) ON CONFLICT DO NOTHING; ANALYZE kiroku.streams;")
        sql(seed, database)
        evidence.setdefault("fixtures", []).append({"database": database, "typeid_streams_per_category": size, "sql": seed})
        for layout in ["category_only", "category_name"]:
            ddl = ("REINDEX INDEX kiroku.ix_streams_category;" if layout == "category_only" else
                   "CREATE INDEX ix_streams_category_name ON kiroku.streams(category,stream_name); "
                   "DROP INDEX kiroku.ix_streams_category;")
            sql(ddl, database)
            definitions = json.loads(sql("SELECT json_agg(json_build_object('name',indexname,'definition',indexdef,"
                                         "'bytes',pg_relation_size((schemaname||'.'||indexname)::regclass)) "
                                         "ORDER BY indexname) FROM pg_indexes "
                                         "WHERE schemaname='kiroku' AND tablename='streams';", database))
            evidence.setdefault("layouts", []).append({
                "database": database, "typeid_streams_per_category": size,
                "layout": layout, "ddl": ddl, "indexes": definitions,
                "table_bytes": int(sql("SELECT pg_relation_size('kiroku.streams');", database)),
                "stream_event_indexes": json.loads(sql("SELECT json_agg(indexdef ORDER BY indexname) "
                    "FROM pg_indexes WHERE schemaname='kiroku' AND tablename='stream_events';", database))})
            for mode in ["force_generic_plan", "force_custom_plan"]:
                for label, category, cursor in [
                    ("first", "orders", None), ("missing", "missing", None),
                    ("late", "orders", "orders-" + fixture_typeid(size - 10)),
                    ("end", "orders", "orders-漢字")]:
                    seek = " AND stream_name > $2" if cursor is not None else ""
                    query = (f"SELECT {COLUMNS} FROM streams WHERE stream_id <> 0 "
                             "AND category = $1" + seek + " ORDER BY stream_name LIMIT $5")
                    parameters = ",".join([sql_text(category), "NULL" if cursor is None else sql_text(cursor),
                                           "NULL", "NULL", "11", "NULL"])
                    reference = "category = " + sql_text(category)
                    range_streams_case(sql, database, evidence, save, mode, str(size), label,
                                       size, size, category, cursor, None, None, None,
                                       layout, query, parameters, reference)
                for variant, cursor in [("category_first", None), ("category_after", "orders")]:
                    query = CATEGORY_VARIANTS[variant]
                    settings = ("SET search_path TO kiroku,pg_catalog; "
                                f"SET plan_cache_mode={mode}; SET statement_timeout='10s'; "
                                f"PREPARE probe(text,integer) AS {query}; ")
                    execute = "EXECUTE probe(" + ("NULL" if cursor is None else sql_text(cursor)) + ",11);"
                    transcript = settings + "EXPLAIN (ANALYZE,BUFFERS,COSTS OFF,TIMING OFF,FORMAT JSON) " + execute
                    plan = json.loads(sql(transcript, database))
                    top = plan[0]["Plan"]
                    actual = sql(settings + execute, database).splitlines()
                    reference = "SELECT DISTINCT category FROM kiroku.streams WHERE stream_id<>0"
                    if cursor is not None:
                        reference += " AND category>" + sql_text(cursor)
                    expected = sql(reference + " ORDER BY category LIMIT 11;", database).splitlines()
                    assert actual == expected, "index replacement changed category enumeration"
                    examined = sum((n.get("Actual Rows", 0) + n.get("Rows Removed by Filter", 0))
                                   * n.get("Actual Loops", 1) for n in nodes(top)
                                   if n.get("Relation Name") == "streams")
                    buffers = top.get("Shared Hit Blocks", 0) + top.get("Shared Read Blocks", 0)
                    evidence["cases"].append({"database": database, "stage": str(size), "mode": mode,
                        "variant": variant, "shape": layout, "sql": transcript, "plan": plan,
                        "rows_examined": examined, "buffers": buffers, "items": actual,
                        "expected_items": expected, "correct_results": True,
                        "within_budget": examined <= 64 and buffers <= 64})
                    save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scope", choices=["prefix", "category-streams", "range-streams", "index-layout"], default="prefix")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output exists; preserve prior evidence and choose a new path")
    started = time.monotonic()
    deadline = started + 300
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}

    def run(command, sql=None):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("five-minute diagnostic deadline exceeded")
        result = subprocess.run(command, input=sql, text=True, capture_output=True,
                                env=env, timeout=min(60, remaining))
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout

    evidence = {"started_at": datetime.now(timezone.utc).isoformat(),
                "scope": "local SQL prototype; no production/append acceptance",
                "query_scope": args.scope,
                "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "page_limit": 11, "row_budget": 64, "buffer_budget": 64,
                "cases": [], "migrations": [], "status": "running"}
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        temporary = args.output.with_suffix(".tmp")
        temporary.write_text(json.dumps(evidence, indent=2) + "\n")
        temporary.replace(args.output)

    save()
    try:
        with tempfile.TemporaryDirectory(prefix="mp13-prefix-", dir="/tmp") as owned:
            data = str(Path(owned) / "data")
            log = str(Path(owned) / "postgres.log")
            run(["initdb", "-D", data, "--auth=trust", "--no-locale", "--encoding=UTF8"])
            # Unix socket only; the cluster is never exposed over TCP.
            try:
                run(["pg_ctl", "-D", data, "-l", log, "-w", "start", "-o",
                     f"-k {owned} -p 55439 -c listen_addresses='' -c fsync=on"])

                def sql(statement, database="postgres"):
                    return run(["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                                "-h", owned, "-p", "55439", "-d", database], statement)

                evidence["server"] = sql("SELECT version()").strip()
                if int(sql("SHOW server_version_num")) // 10000 != 18:
                    raise RuntimeError("this diagnostic requires PostgreSQL 18")
                # The cohort may not impose C ordering on existing deployments.
                sql("CREATE DATABASE prefix_icu TEMPLATE template0 LOCALE_PROVIDER icu ICU_LOCALE 'en';")
                for database in ["postgres", "prefix_icu"]:
                    for migration in sorted((ROOT / "kiroku-store-migrations/migrations").glob("*.sql")):
                        raw = migration.read_bytes()
                        sql("SET search_path TO kiroku, pg_catalog;\n" + raw.decode(), database)
                        if database == "postgres":
                            evidence["migrations"].append({"path": str(migration.relative_to(ROOT)),
                                                           "sha256": hashlib.sha256(raw).hexdigest()})
                    evidence.setdefault("indexes", {})[database] = json.loads(sql(
                        "SELECT json_agg(indexdef ORDER BY indexname) FROM pg_indexes "
                        "WHERE schemaname='kiroku' AND tablename='streams';", database))
                    if args.scope == "category-streams":
                        category_streams_probe(sql, database, evidence, save)
                        continue
                    if args.scope == "range-streams":
                        range_streams_probe(sql, database, evidence, save)
                        continue
                    if args.scope == "index-layout":
                        index_layout_probe(sql, database, evidence, save)
                        continue
                    for size in [1000, 20000]:
                        sql("SET search_path TO kiroku, pg_catalog;\n"
                            f"INSERT INTO streams(stream_name) SELECT 'noise-' || lpad(n::text,6,'0') "
                            f"FROM generate_series(1,{size}) n ON CONFLICT DO NOTHING;\n"
                            "INSERT INTO streams(stream_name) VALUES ('orders-1'),('orders-2') ON CONFLICT DO NOTHING;\n"
                            "ANALYZE streams;", database)
                        for mode in ["force_generic_plan", "force_custom_plan"]:
                            for variant, query in VARIANTS.items():
                                for cursor, prefix in [(None, "orders-"), (None, "absent-"),
                                                       ("noise-000500", "absent-"),
                                                       (f"noise-{size-10:06}", "absent-"),
                                                       ("orders-1", "orders-")]:
                                    if variant.startswith("after_") and cursor is None:
                                        continue
                                    if variant == "first_prefix" and cursor is not None:
                                        continue
                                    cursor_sql = "NULL" if cursor is None else "'" + cursor + "'"
                                    command = f"EXECUTE probe({cursor_sql}, '{prefix}', 11)"
                                    transcript = ("SET search_path TO kiroku, pg_catalog;\n"
                                                  f"SET plan_cache_mode = {mode};\n"
                                                  "SET statement_timeout = '10s';\n"
                                                  f"PREPARE probe(text,text,integer) AS {query};\n"
                                                  "EXPLAIN (ANALYZE,BUFFERS,COSTS OFF,TIMING OFF,FORMAT JSON) "
                                                  + command + ";\n")
                                    plan = json.loads(sql(transcript, database))
                                    top = plan[0]["Plan"]
                                    scans = [n for n in nodes(top) if "Scan" in n.get("Node Type", "")]
                                    examined = sum((n.get("Actual Rows", 0) + n.get("Rows Removed by Filter", 0)
                                                    + n.get("Rows Removed by Index Recheck", 0))
                                                   * n.get("Actual Loops", 1) for n in scans)
                                    buffers = top.get("Shared Hit Blocks", 0) + top.get("Shared Read Blocks", 0)
                                    row = {"database": database, "inventory_noise": size, "mode": mode,
                                           "variant": variant, "cursor": cursor, "prefix": prefix,
                                           "sql": transcript, "plan": plan, "rows_examined": examined,
                                           "buffers": buffers,
                                           "within_budget": examined <= 64 and buffers <= 64}
                                    evidence["cases"].append(row)
                                    save()
                            for variant, query in CATEGORY_VARIANTS.items():
                                for cursor in [None, "noise", "orders"]:
                                    if variant == "category_first" and cursor is not None:
                                        continue
                                    if variant == "category_after" and cursor is None:
                                        continue
                                    cursor_sql = "NULL" if cursor is None else "'" + cursor + "'"
                                    transcript = ("SET search_path TO kiroku, pg_catalog;\n"
                                                  f"SET plan_cache_mode = {mode};\n"
                                                  "SET statement_timeout = '10s';\n"
                                                  f"PREPARE probe(text,integer) AS {query};\n"
                                                  "EXPLAIN (ANALYZE,BUFFERS,COSTS OFF,TIMING OFF,FORMAT JSON) "
                                                  f"EXECUTE probe({cursor_sql}, 11);\n")
                                    plan = json.loads(sql(transcript, database))
                                    top = plan[0]["Plan"]
                                    scans = [n for n in nodes(top) if "Scan" in n.get("Node Type", "")
                                             and n.get("Relation Name") == "streams"]
                                    examined = sum((n.get("Actual Rows", 0) + n.get("Rows Removed by Filter", 0))
                                                   * n.get("Actual Loops", 1) for n in scans)
                                    buffers = top.get("Shared Hit Blocks", 0) + top.get("Shared Read Blocks", 0)
                                    evidence["cases"].append({
                                        "database": database, "inventory_noise": size, "mode": mode,
                                        "variant": variant, "cursor": cursor, "sql": transcript, "plan": plan,
                                        "rows_examined": examined, "buffers": buffers,
                                        "within_budget": examined <= 64 and buffers <= 64})
                                    save()
                required_cases = [r for r in evidence["cases"]
                                  if args.scope in ["category-streams", "range-streams", "index-layout"] or r["variant"] == "nullable"]
                if not required_cases:
                    raise RuntimeError("no required SQL cases were evaluated")
                if args.scope == "index-layout":
                    candidate = [r for r in required_cases if r["shape"] == "category_name"]
                    evidence["candidate_read_cases_pass"] = bool(candidate) and all(r["within_budget"] for r in candidate)
                    evidence["status"] = "index_layout_research_complete"
                else:
                    evidence["status"] = "passes_focused_check" if all(
                        r["within_budget"] for r in required_cases
                    ) else {"category-streams": "category_streams_requires_design",
                        "range-streams": "range_streams_requires_design",
                        "prefix": "rejected_prefix_prototype"}[args.scope]
            finally:
                # Stop even when startup, migration or a query fails. No owned cluster survives.
                stopped = subprocess.run(["pg_ctl", "-D", data, "-w", "-m", "immediate", "stop"],
                                         capture_output=True, text=True, timeout=30, env=env)
                evidence["cluster_stopped"] = stopped.returncode == 0
                if stopped.returncode and Path(data, "postmaster.pid").exists():
                    raise RuntimeError("owned PostgreSQL cluster could not be stopped: " + stopped.stderr)
                evidence["postgres_log"] = Path(log).read_text() if Path(log).exists() else ""
    except BaseException as error:
        evidence["status"] = "error"
        evidence["error"] = str(error)
        raise
    finally:
        evidence["elapsed_seconds"] = time.monotonic() - started
        save()
    print(json.dumps({k: evidence[k] for k in ["status", "server", "cluster_stopped", "elapsed_seconds"]}, indent=2))
    return 0 if evidence["status"] in ["passes_focused_check", "index_layout_research_complete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
