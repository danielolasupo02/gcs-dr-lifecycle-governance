"""Phase 03: verify the lifecycle rules on both buckets and simulate an object's life under them.

Lifecycle transitions take at least 30 days to happen for real, so this script proves the
policy two ways instead:
  1. Reads the live rules from each bucket and checks them against the expected thresholds.
  2. Replays those exact rules day by day for a new live object and checks which storage
     class it is in at the boundary days.

Usage:
  python scripts/phase-03/verify_lifecycle.py <project-id> <nearline-days> <coldline-days> <bucket> [<bucket> ...]
Exit 0 when every check passes, 1 otherwise.
"""
import sys

from google.api_core import exceptions
from google.cloud import storage

# Cheapest at-rest price wins when several SetStorageClass rules match on the same day.
COLDNESS = {"STANDARD": 0, "NEARLINE": 1, "COLDLINE": 2, "ARCHIVE": 3}
HORIZON_DAYS = 2555  # 7 years, a common retention period for banking records


def transition_rules(rules):
    return [r for r in rules if r.get("action", {}).get("type") == "SetStorageClass"]


def find_transition(rules, target):
    for r in transition_rules(rules):
        if r["action"].get("storageClass") == target:
            return r
    return None


def simulate(rules, day):
    """Storage class of a live object, created as STANDARD, after `day` days."""
    current = "STANDARD"
    transitions = transition_rules(rules)
    for d in range(day + 1):
        eligible = []
        for r in transitions:
            cond = r.get("condition", {})
            if cond.get("isLive") is False:
                continue
            if d < cond.get("age", 0):
                continue
            if "matchesStorageClass" in cond and current not in cond["matchesStorageClass"]:
                continue
            eligible.append(r["action"]["storageClass"])
        if eligible:
            coldest = max(eligible, key=COLDNESS.get)
            if COLDNESS[coldest] > COLDNESS[current]:
                current = coldest
    return current


def check_bucket(client, name, nearline, coldline):
    print(f"\nBucket: gs://{name}")
    try:
        rules = list(client.get_bucket(name).lifecycle_rules)
    except (exceptions.NotFound, exceptions.Forbidden) as err:
        print(f"  [FAIL] cannot read bucket: {err}")
        return 0, 1

    print(f"  {'action':<32} {'condition'}")
    for r in rules:
        action = r["action"]["type"] + (f" -> {r['action']['storageClass']}" if "storageClass" in r["action"] else "")
        print(f"  {action:<32} {r.get('condition', {})}")

    nl = find_transition(rules, "NEARLINE") or {}
    cl = find_transition(rules, "COLDLINE") or {}
    nlc, clc = nl.get("condition", {}), cl.get("condition", {})
    actions = [r["action"]["type"] for r in rules]

    checks = [
        ("4 lifecycle rules present", len(rules) == 4),
        (f"NEARLINE transition at age {nearline}", nlc.get("age") == nearline),
        ("NEARLINE rule only matches STANDARD objects", nlc.get("matchesStorageClass") == ["STANDARD"]),
        (f"COLDLINE transition at age {coldline}", clc.get("age") == coldline),
        ("COLDLINE rule matches STANDARD and NEARLINE", sorted(clc.get("matchesStorageClass", [])) == ["NEARLINE", "STANDARD"]),
        ("transitions apply to live versions only", nlc.get("isLive") is True and clc.get("isLive") is True),
        ("noncurrent version cleanup still present", "Delete" in actions),
        ("stale multipart upload abort still present", "AbortIncompleteMultipartUpload" in actions),
    ]

    timeline = [
        (0, "STANDARD"),
        (nearline - 1, "STANDARD"),
        (nearline, "NEARLINE"),
        (coldline - 1, "NEARLINE"),
        (coldline, "COLDLINE"),
        (HORIZON_DAYS, "COLDLINE"),
    ]
    for day, expected in timeline:
        got = simulate(rules, day)
        checks.append((f"simulated day {day:>4}: {expected} (got {got})", got == expected))

    passed = failed = 0
    print()
    for desc, ok in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {desc}")
        passed += ok
        failed += not ok
    return passed, failed


def main(argv):
    if len(argv) < 5:
        print(__doc__)
        return 2
    project, nearline, coldline, buckets = argv[1], int(argv[2]), int(argv[3]), argv[4:]
    client = storage.Client(project=project)

    total_pass = total_fail = 0
    for name in buckets:
        p, f = check_bucket(client, name, nearline, coldline)
        total_pass += p
        total_fail += f

    print(f"\nLifecycle: {total_pass} passed, {total_fail} failed")
    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
