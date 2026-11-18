"""Minimal Alertmanager webhook receiver: one JSON line per alert to stdout and /data/alerts.jsonl.

Stands in for Slack, email or PagerDuty in the lab, so delivery can be checked by a script.
"""
import datetime as dt
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = os.getenv("ALERT_LOG", "/data/alerts.jsonl")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        with open(LOG, "a") as fh:
            for alert in body.get("alerts", []):
                line = {
                    "received_at": now,
                    "status": alert.get("status"),
                    "alertname": alert.get("labels", {}).get("alertname"),
                    "severity": alert.get("labels", {}).get("severity"),
                    "summary": alert.get("annotations", {}).get("summary"),
                }
                fh.write(json.dumps(line) + "\n")
                print(json.dumps(line), flush=True)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):  # silence default access log
        pass


if __name__ == "__main__":
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    print(f"alert receiver listening on :5001, writing {LOG}", flush=True)
    HTTPServer(("0.0.0.0", 5001), Handler).serve_forever()
