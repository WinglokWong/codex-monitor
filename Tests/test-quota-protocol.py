#!/usr/bin/env python3
"""Exercise the built monitor's stdio protocol with a synthetic Codex CLI.

Run after ./build.sh:
    python3 Tests/test-quota-protocol.py
    python3 Tests/test-quota-protocol.py --binary /path/to/CodexMonitor

The fake CLI never reads credentials, starts real Codex, or makes network/model
requests. Application-state retention/clearing is covered by --self-test.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/Codex Monitor.app/Contents/MacOS/CodexMonitor"
EMAIL = "synthetic.alice@example.test"
CHANGED_EMAIL = "synthetic.bob@example.test"
SAME_MASK_EMAIL = "symphonic.anne@example.test"
MASKED_EMAIL = "sy***e@example.test"
PRIVATE_DIAGNOSTIC = "SYNTHETIC_PRIVATE_DIAGNOSTIC_DO_NOT_DISPLAY"


def weekly_limits() -> dict:
    return {
        "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": {
                "usedPercent": 5,
                "windowDurationMins": 300,
                "resetsAt": 1_893_456_000,
            },
            "secondary": {
                "usedPercent": 27,
                "windowDurationMins": 10_080,
                "resetsAt": 1_893_456_000,
            },
        },
        "rateLimitsByLimitId": None,
    }


def fake_cli() -> int:
    """This same file is re-entered by the temporary executable CLI wrapper."""
    if sys.argv[2:] != ["app-server", "--listen", "stdio://"]:
        return 2
    scenario = os.environ["CODEX_MONITOR_PROTOCOL_CASE"]
    trace = Path(os.environ["CODEX_MONITOR_PROTOCOL_TRACE"])
    account_reads = 0

    def emit(message: dict) -> None:
        print(json.dumps(message), flush=True)

    def fail(request_id: object) -> None:
        emit({
            "id": request_id,
            "error": {
                "code": -32603,
                "message": f"{PRIVATE_DIAGNOSTIC}: {EMAIL}",
            },
        })

    for line in sys.stdin:
        request = json.loads(line)
        with trace.open("a", encoding="utf-8") as output:
            output.write(json.dumps(request) + "\n")
        method = request.get("method")
        request_id = request.get("id")
        if method == "initialize":
            emit({"id": request_id, "result": {"userAgent": "SyntheticCodex/1.1.0"}})
        elif method == "initialized":
            continue
        elif method == "account/read":
            account_reads += 1
            if scenario == "account_error":
                fail(request_id)
                continue
            if scenario == "malformed_json":
                print("{synthetic invalid JSON", flush=True)
                continue
            if scenario == "signed_out":
                account = None
            elif scenario == "api_key":
                account = {"type": "apiKey"}
            else:
                account = {"type": "chatgpt", "email": EMAIL, "planType": "plus"}
                if account_reads > 1 and scenario == "silent_account_changed":
                    account["email"] = CHANGED_EMAIL
                if account_reads > 1 and scenario == "same_mask_account_changed":
                    account["email"] = SAME_MASK_EMAIL
            emit({"id": request_id, "result": {
                "account": account,
                "requiresOpenaiAuth": scenario != "api_key",
            }})
        elif method == "account/rateLimits/read":
            if scenario == "quota_error":
                fail(request_id)
                continue
            if scenario == "account_changed":
                emit({"method": "account/updated", "params": {
                    "authMode": "chatgpt", "planType": "pro",
                }})
            # Even after a switch, deliberately send the old reading. The client
            # must reject it instead of pairing it with a different identity.
            emit({"id": request_id, "result": weekly_limits()})
        else:
            emit({"id": request_id, "error": {"code": -32601, "message": "Unknown synthetic method"}})
    return 0


class QuotaProtocolTests(unittest.TestCase):
    def probe(self, scenario: str) -> tuple[subprocess.CompletedProcess, dict, list[dict]]:
        self.assertTrue(BINARY.is_file(), f"Build the monitor first: {BINARY}")
        with tempfile.TemporaryDirectory(prefix="codex-monitor-protocol-") as directory:
            temporary = Path(directory)
            trace = temporary / "requests.jsonl"
            fake = temporary / "codex"
            fake.write_text(
                "#!/bin/sh\nexec "
                + shlex.quote(sys.executable)
                + " "
                + shlex.quote(str(Path(__file__).resolve()))
                + ' --fake-cli "$@"\n',
                encoding="utf-8",
            )
            fake.chmod(0o700)
            environment = os.environ.copy()
            environment.update({
                "CODEX_MONITOR_CLI": str(fake),
                "CODEX_MONITOR_PROTOCOL_CASE": scenario,
                "CODEX_MONITOR_PROTOCOL_TRACE": str(trace),
            })
            completed = subprocess.run(
                [str(BINARY), "--probe"],
                env=environment,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
            for raw_email in [EMAIL, CHANGED_EMAIL, SAME_MASK_EMAIL]:
                self.assertNotIn(raw_email, completed.stdout + completed.stderr, "Raw synthetic email leaked")
            self.assertNotIn(PRIVATE_DIAGNOSTIC, completed.stdout + completed.stderr, "Private server diagnostics leaked")
            try:
                output = json.loads(completed.stdout)
            except json.JSONDecodeError as error:
                self.fail(f"Probe did not emit JSON (exit {completed.returncode}): {error}; stderr={completed.stderr!r}")
            requests = [json.loads(line) for line in trace.read_text(encoding="utf-8").splitlines()] if trace.exists() else []
            return completed, output, requests

    def assert_requests(self, requests: list[dict], *, quota: bool, confirm: bool = False) -> None:
        expected = ["initialize", "initialized", "account/read"]
        if quota:
            expected.append("account/rateLimits/read")
        if confirm:
            expected.append("account/read")
        self.assertEqual([request.get("method") for request in requests], expected)
        for request in requests:
            if request.get("method") == "account/read":
                self.assertEqual(request.get("params"), {"refreshToken": False})
        request_ids = [request["id"] for request in requests if "id" in request]
        self.assertEqual(len(request_ids), len(set(request_ids)), "Request IDs must be unique")

    def assert_failed_read(self, scenario: str, *, quota: bool, confirm: bool = False) -> None:
        completed, output, requests = self.probe(scenario)
        self.assertEqual(completed.returncode, 1)
        self.assertTrue(output.get("quotaError"))
        self.assertIsNone(output.get("account"), "Failed paired read must not publish account identity")
        self.assertFalse(output.get("weeklyQuota"), "Failed paired read must not publish quota")
        self.assert_requests(requests, quota=quota, confirm=confirm)

    def test_chatgpt_identity_is_masked_and_paired_with_weekly_quota(self) -> None:
        completed, output, requests = self.probe("chatgpt")
        self.assertEqual(completed.returncode, 0)
        self.assertNotIn("quotaError", output)
        self.assertEqual(output["account"], {
            "authType": "chatgpt",
            "displayName": MASKED_EMAIL,
            "maskedEmail": MASKED_EMAIL,
            "planName": "Plus",
        })
        self.assertEqual(len(output["weeklyQuota"]), 1)
        self.assertEqual(output["weeklyQuota"][0]["remainingPercent"], 73)
        self.assertEqual(output["weeklyQuota"][0]["id"], "codex.secondary")
        self.assert_requests(requests, quota=True, confirm=True)

    def test_logged_out_account_does_not_query_or_publish_weekly_quota(self) -> None:
        completed, output, requests = self.probe("signed_out")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(output["account"]["authType"], "signedOut")
        self.assertEqual(output["account"]["displayName"], "未登录")
        self.assertIsNone(output["account"]["maskedEmail"])
        self.assertIsNone(output["account"]["planName"])
        self.assertEqual(output["weeklyQuota"], [])
        self.assert_requests(requests, quota=False)

    def test_api_key_account_does_not_query_or_publish_weekly_quota(self) -> None:
        completed, output, requests = self.probe("api_key")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(output["account"]["authType"], "apiKey")
        self.assertEqual(output["account"]["displayName"], "API Key")
        self.assertIsNone(output["account"]["maskedEmail"])
        self.assertIsNone(output["account"]["planName"])
        self.assertEqual(output["weeklyQuota"], [])
        self.assert_requests(requests, quota=False)

    def test_account_switch_rejects_old_account_quota(self) -> None:
        self.assert_failed_read("account_changed", quota=True)

    def test_silent_account_switch_is_caught_by_identity_confirmation(self) -> None:
        self.assert_failed_read("silent_account_changed", quota=True, confirm=True)

    def test_accounts_with_the_same_mask_are_not_treated_as_the_same_identity(self) -> None:
        self.assert_failed_read("same_mask_account_changed", quota=True, confirm=True)

    def test_account_protocol_error_is_sanitized(self) -> None:
        self.assert_failed_read("account_error", quota=False)

    def test_quota_protocol_error_does_not_publish_partial_identity(self) -> None:
        self.assert_failed_read("quota_error", quota=True)

    def test_malformed_protocol_reply_fails_without_partial_data(self) -> None:
        self.assert_failed_read("malformed_json", quota=False)


def main() -> int:
    global BINARY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=BINARY, help="Built CodexMonitor executable")
    arguments = parser.parse_args()
    BINARY = arguments.binary.expanduser().resolve()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(QuotaProtocolTests)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake-cli":
        raise SystemExit(fake_cli())
    raise SystemExit(main())
