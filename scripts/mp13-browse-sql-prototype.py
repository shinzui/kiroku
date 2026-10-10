#!/usr/bin/env python3
"""Check EP-3's SQL promotion gate on a disposable PostgreSQL 18 cluster.

No production SQL is installed. Exit 2 means the prefix prototype is rejected;
exit 0 means only this focused check passed, not cumulative observer acceptance.
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
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
                evidence["status"] = "passes_focused_check" if all(
                    r["within_budget"] for r in evidence["cases"] if r["variant"] == "nullable"
                ) else "rejected_prefix_prototype"
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
    return 2 if evidence["status"] == "rejected_prefix_prototype" else 0


if __name__ == "__main__":
    raise SystemExit(main())
