"""Phase 07: recovery drills on the validation document.

  restore    Primary copy is lost (deleted). Restore it from the secondary region and
             confirm it is re-encrypted with the primary key.
  rollback   A bad revision is live. Roll the primary back to version 1 from its own
             version history.

Run validate_deployment.py first; it creates the document and its two versions.

Usage: python scripts/phase-07/dr_drills.py restore|rollback <project> <primary> <secondary> <primary-key>
"""
import os
import sys

from google.api_core import exceptions
from google.cloud import storage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from archive_lib import check, print_versions, rewrite_into, summary, versions  # noqa: E402

DOC = "validation/test-document.txt"


def drill_restore(client, primary, secondary, p_key):
    print("\nDrill: restore the primary copy from the secondary region")
    source = secondary.get_blob(DOC)
    if not check("secondary has a live copy to restore from", source is not None):
        return
    expected = source.download_as_bytes()

    primary.blob(DOC).delete()
    check("primary live copy deleted (simulated loss)", primary.get_blob(DOC) is None)

    # Server-side rewrite across regions, re-encrypted with the primary key. The primary's
    # enforcement config applies to this write like any other.
    restored = rewrite_into(source, primary, DOC, p_key)
    check("primary live copy restored", restored is not None)
    check("restored content matches the secondary copy", restored.download_as_bytes() == expected)
    check("restored copy is encrypted with the primary key", (restored.kms_key_name or "").startswith(p_key + "/"))
    print(f"  equivalent command: gcloud storage cp gs://{secondary.name}/{DOC} gs://{primary.name}/{DOC}")


def drill_rollback(client, primary, p_key):
    print("\nDrill: roll the primary back to version 1")
    history = versions(client, primary, DOC)
    good = next((b for b in history if b"version 1" in b.download_as_bytes()), None)
    if not check("version 1 found in primary version history", good is not None):
        return
    expected = good.download_as_bytes()

    live = rewrite_into(good, primary, DOC, p_key)
    check(f"live content is version 1 again (copied from generation {good.generation})", live.download_as_bytes() == expected)
    check("rollback created a new generation; history is preserved", len(versions(client, primary, DOC)) == len(history) + 1)
    print(f"  equivalent command: gcloud storage cp gs://{primary.name}/{DOC}#{good.generation} gs://{primary.name}/{DOC}")
    print_versions(client, primary, DOC)


def main(argv):
    if len(argv) != 6 or argv[1] not in ("restore", "rollback"):
        print(__doc__)
        return 2
    cmd, project, p_name, s_name, p_key = argv[1:]
    client = storage.Client(project=project)
    primary, secondary = client.bucket(p_name), client.bucket(s_name)
    try:
        if cmd == "restore":
            drill_restore(client, primary, secondary, p_key)
        else:
            drill_rollback(client, primary, p_key)
    except exceptions.GoogleAPICallError as err:
        check(f"API call failed: {err.__class__.__name__}: {err.message[:100]}", False)
    return summary(f"Drill ({cmd})")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
