#!/usr/bin/env python3
"""Phase 08: query and verify the Cloud Storage access logs routed to BigQuery.

Subcommands:
  check          dataset exists and the sink's writer identity can write to it
  trace OBJECT   wait until a write to OBJECT (e.g. a probe) appears in the logs
  denied PRINCIPAL  wait until a refused request by PRINCIPAL appears in the logs
  tamper         try to create a table in the log dataset (must be refused for the auditor)
  report         run every queries/*.sql and print the results

Common options: --project, --dataset, [--impersonate SA], [--sink-writer MEMBER]

Exit codes: 0 success, 1 a check failed, 2 the command could not run.
"""
import argparse
import glob
import os
import sys
import time

import google.auth
import google.auth.exceptions
from google.api_core import exceptions
from google.auth import impersonated_credentials
from google.cloud import bigquery

SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]
DATA_ACCESS = "cloudaudit_googleapis_com_data_access"
POLL_S = 30
TIMEOUT_S = 900
HERE = os.path.dirname(os.path.abspath(__file__))


def credentials(impersonate):
    source, _ = google.auth.default(scopes=SCOPES)
    if not impersonate:
        return source
    return impersonated_credentials.Credentials(
        source_credentials=source, target_principal=impersonate, target_scopes=SCOPES, lifetime=900
    )


def ok(desc, passed):
    print(f"  [{'PASS' if passed else 'FAIL'}] {desc}")
    return passed


def poll(client, sql, params, label):
    """Re-run sql until it returns a row. Logs reach BigQuery a few minutes after the event."""
    start = time.monotonic()
    print(f"  waiting for {label} in BigQuery (timeout {TIMEOUT_S // 60} min)", flush=True)
    while time.monotonic() - start < TIMEOUT_S:
        try:
            rows = list(client.query(sql, job_config=bigquery.QueryJobConfig(query_parameters=params)).result())
            if rows:
                return round(time.monotonic() - start), rows[0]
        except exceptions.NotFound:
            pass  # table is created by the sink when the first matching log arrives
        time.sleep(POLL_S)
        print(f"    ... {round(time.monotonic() - start)}s", flush=True)
    return None, None


def cmd_check(client, args):
    ds = client.get_dataset(f"{args.project}.{args.dataset}")
    results = [ok(f"dataset {ds.dataset_id} exists in {ds.location}", True)]
    member = (args.sink_writer or "").split(":", 1)[-1]
    writers = {
        e.entity_id for e in ds.access_entries
        if e.role in ("WRITER", "roles/bigquery.dataEditor") and e.entity_id
    }
    results.append(ok("sink writer identity can write to the dataset", member in writers))
    tables = {t.table_id for t in client.list_tables(ds)}
    print(f"  tables: {', '.join(sorted(tables)) or '(none yet)'}")
    return all(results)


def cmd_trace(client, args):
    sql = f"""
        SELECT timestamp, protopayload_auditlog.authenticationInfo.principalEmail AS principal,
               protopayload_auditlog.methodName AS method
        FROM `{args.project}.{args.dataset}.{DATA_ACCESS}`
        WHERE protopayload_auditlog.resourceName LIKE @pattern
          AND protopayload_auditlog.methodName = 'storage.objects.create'
        ORDER BY timestamp DESC LIMIT 1"""
    params = [bigquery.ScalarQueryParameter("pattern", "STRING", f"%/objects/{args.target}")]
    secs, row = poll(client, sql, params, f"the write of {args.target}")
    if not ok(f"write of {args.target} found in BigQuery" + (f" after {secs}s" if secs is not None else ""), row is not None):
        return False
    print(f"  {row.timestamp}  {row.principal}  {row.method}")
    return True


def cmd_denied(client, args):
    sql = f"""
        SELECT timestamp, protopayload_auditlog.methodName AS method,
               protopayload_auditlog.status.code AS code, protopayload_auditlog.status.message AS message
        FROM `{args.project}.{args.dataset}.{DATA_ACCESS}`
        WHERE protopayload_auditlog.authenticationInfo.principalEmail = @principal
          AND protopayload_auditlog.status.code = 7
          AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
        ORDER BY timestamp DESC LIMIT 1"""
    params = [bigquery.ScalarQueryParameter("principal", "STRING", args.target)]
    secs, row = poll(client, sql, params, f"a denied request by {args.target}")
    if not ok("denied request recorded with PERMISSION_DENIED (code 7)" + (f" after {secs}s" if secs is not None else ""), row is not None):
        return False
    print(f"  {row.timestamp}  {row.method}  code {row.code}: {(row.message or '')[:90]}")
    return True


def cmd_tamper(client, args):
    table = bigquery.Table(f"{args.project}.{args.dataset}.tamper_test_{int(time.time())}",
                           schema=[bigquery.SchemaField("x", "STRING")])
    try:
        client.create_table(table)
    except exceptions.Forbidden as err:
        return ok(f"creating a table in the log dataset is refused (403: {err.message[:70]})", True)
    client.delete_table(table, not_found_ok=True)
    return ok("creating a table in the log dataset is refused (it SUCCEEDED and was removed)", False)


def print_rows(rows):
    rows = list(rows)
    if not rows:
        print("    (no rows)")
        return
    cols = list(rows[0].keys())
    fmt = lambda v: str(v)[:46] if v is not None else ""  # noqa: E731
    widths = [max(len(c), *(len(fmt(r[c])) for r in rows)) for c in cols]
    print("    " + "  ".join(c.ljust(w) for c, w in zip(cols, widths)))
    for r in rows:
        print("    " + "  ".join(fmt(r[c]).ljust(w) for c, w in zip(cols, widths)))


def cmd_report(client, args):
    all_ok = True
    for path in sorted(glob.glob(os.path.join(HERE, "queries", "*.sql"))):
        name = os.path.basename(path)
        sql = open(path).read().replace("{project}", args.project).replace("{dataset}", args.dataset)
        print(f"\n== {name}")
        try:
            print_rows(client.query(sql).result())
        except exceptions.NotFound:
            print("    (log table not created yet: no matching events routed since the sink was created)")
        except exceptions.GoogleAPICallError as err:
            print(f"    FAILED: {err.__class__.__name__}: {err.message[:120]}")
            all_ok = False
    return all_ok


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["check", "trace", "denied", "tamper", "report"])
    p.add_argument("target", nargs="?", help="object name for trace, principal email for denied")
    p.add_argument("--project", required=True)
    p.add_argument("--dataset", default="gcs_access_logs")
    p.add_argument("--impersonate")
    p.add_argument("--sink-writer")
    args = p.parse_args(argv)

    if args.command in ("trace", "denied") and not args.target:
        p.error(f"{args.command} needs a target")

    try:
        client = bigquery.Client(project=args.project, credentials=credentials(args.impersonate))
        who = args.impersonate or "you (Application Default Credentials)"
        print(f"{args.command} as {who}")
        handler = {"check": cmd_check, "trace": cmd_trace, "denied": cmd_denied,
                   "tamper": cmd_tamper, "report": cmd_report}[args.command]
        return 0 if handler(client, args) else 1
    except exceptions.NotFound as err:
        print(f"ERROR: not found: {err.message}", file=sys.stderr)
    except exceptions.Forbidden as err:
        print(f"ERROR: permission denied: {err.message}", file=sys.stderr)
    except google.auth.exceptions.GoogleAuthError as err:
        print(f"ERROR: authentication failed: {err}", file=sys.stderr)
    except exceptions.GoogleAPICallError as err:
        print(f"ERROR: API call failed: {err}", file=sys.stderr)
    except Exception as err:  # never crash with a traceback
        print(f"ERROR: unexpected {err.__class__.__name__}: {err}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
