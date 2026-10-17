"""mafest DB 자격 전달 도구와 libpq의 PGPASSWORD 동작을 합성 값으로 시험한다.

클러스터에 접속하지 않는다. 가짜 kubectl 스크립트와 로컬 소켓 위의 가짜 Postgres 서버만 쓴다.
실행: python3 -I scripts/test_mafest_credentials.py
"""

from __future__ import annotations

import base64
import json
import os
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

import psycopg2
from psycopg2 import extensions

SCRIPTS_DIR = Path(__file__).resolve().parent
SYNC_TOOL = SCRIPTS_DIR / "mafest_sync_db_secret.py"

# URL 예약 문자, 공백, 따옴표를 모두 넣은 합성 비밀번호. 실제 값이 아니다.
SYNTHETIC_PASSWORD = "p@ss:/?#[]%&= \"x'y"
SYNTHETIC_PASSWORD_B64 = base64.b64encode(SYNTHETIC_PASSWORD.encode()).decode()

FAKE_KUBECTL = """#!/usr/bin/env python3
import json, os, sys
log = os.environ["FAKE_KUBECTL_LOG"]
argv = sys.argv[1:]
if argv[:1] != ["--context"]:
    sys.stderr.write("context missing")
    sys.exit(7)
context, args = argv[1], argv[2:]
stdin = "" if sys.stdin.isatty() else sys.stdin.read()
with open(log, "a") as handle:
    handle.write(json.dumps({"context": context, "argv": args, "stdin": stdin}) + "\\n")
mode = os.environ.get("FAKE_KUBECTL_MODE", "ok")
if mode == "fail":
    sys.stderr.write("error: leaked " + os.environ["FAKE_KUBECTL_LEAK"])
    sys.exit(1)
if args[0] == "get":
    data = {} if mode == "missing-key" else {"password": os.environ["FAKE_KUBECTL_VALUE"]}
    print(json.dumps({"data": data}))
"""


class FakePostgres(threading.Thread):
    """평문 비밀번호 인증만 요청하고 받은 비밀번호를 기록하는 최소 서버."""

    def __init__(self) -> None:
        super().__init__(daemon=True)
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.received_password: str | None = None

    def run(self) -> None:
        conn, _ = self.sock.accept()
        with conn:
            length = struct.unpack("!I", conn.recv(4))[0]
            body = conn.recv(length - 4)
            if struct.unpack("!I", body[:4])[0] == 80877103:  # SSLRequest
                conn.sendall(b"N")
                length = struct.unpack("!I", conn.recv(4))[0]
                conn.recv(length - 4)
            conn.sendall(
                b"R" + struct.pack("!II", 8, 3)
            )  # AuthenticationCleartextPassword
            if conn.recv(1) == b"p":
                size = struct.unpack("!I", conn.recv(4))[0]
                self.received_password = conn.recv(size - 4).rstrip(b"\0").decode()
            error = b"SFATAL\0C28P01\0Mauth rejected by test server\0\0"
            conn.sendall(b"E" + struct.pack("!I", len(error) + 4) + error)
        self.sock.close()


class LibpqPasswordDeliveryTest(unittest.TestCase):
    def test_passwordless_dsn_uses_pgpassword_with_special_characters(self) -> None:
        # 준비: 앱의 merge_dsn과 같은 parse_dsn → make_dsn 경로로 비밀번호 없는 DSN을 만든다.
        server = FakePostgres()
        server.start()
        params = extensions.parse_dsn(
            f"postgresql://mafest_test@127.0.0.1:{server.port}/db?sslmode=disable&connect_timeout=2"
        )
        dsn = extensions.make_dsn(**params)
        self.assertNotIn("password", dsn)

        # 실행: PGPASSWORD만 환경변수로 준다.
        previous = os.environ.get("PGPASSWORD")
        os.environ["PGPASSWORD"] = SYNTHETIC_PASSWORD
        try:
            with self.assertRaises(psycopg2.OperationalError) as caught:
                psycopg2.connect(dsn)
        finally:
            if previous is None:
                os.environ.pop("PGPASSWORD", None)
            else:
                os.environ["PGPASSWORD"] = previous
        server.join(timeout=5)

        # 검증: 서버는 원문 그대로 받았고, 인증 실패 예외 문구에는 비밀번호가 없다.
        self.assertEqual(server.received_password, SYNTHETIC_PASSWORD)
        self.assertNotIn(SYNTHETIC_PASSWORD, str(caught.exception))
        self.assertNotIn(SYNTHETIC_PASSWORD, dsn)


class SyncToolTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log = Path(self.tmp.name) / "calls.jsonl"
        fake = Path(self.tmp.name) / "kubectl"
        fake.write_text(FAKE_KUBECTL)
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.env = {
            **os.environ,
            "MAFEST_KUBECTL": str(fake),
            "FAKE_KUBECTL_LOG": str(self.log),
            "FAKE_KUBECTL_VALUE": SYNTHETIC_PASSWORD_B64,
            "FAKE_KUBECTL_LEAK": SYNTHETIC_PASSWORD,
        }

    def run_tool(self, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(SYNC_TOOL), *args],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_no_secret_in(self, result: subprocess.CompletedProcess[str]) -> None:
        for text in (result.stdout, result.stderr):
            self.assertNotIn(SYNTHETIC_PASSWORD, text)
            self.assertNotIn(SYNTHETIC_PASSWORD_B64, text)

    def test_default_mode_prints_plan_without_calling_kubectl(self) -> None:
        result = self.run_tool()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_apply_without_matching_confirmation_is_rejected(self) -> None:
        result = self.run_tool("--apply", "--confirm", "other")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_apply_sends_value_by_stdin_only_and_adds_single_key(self) -> None:
        result = self.run_tool(
            "--apply", "--confirm", "mafest-api-db", "--expect-context", "ctx-test"
        )
        self.assertEqual(result.returncode, 0)
        self.assert_no_secret_in(result)
        get_call, patch_call = self.calls()
        self.assertEqual(get_call["argv"][:2], ["get", "secret"])
        self.assertEqual(
            json.loads(patch_call["stdin"]),
            {"data": {"PGPASSWORD": SYNTHETIC_PASSWORD_B64}},
        )
        # 값이 명령줄 인자(ps에 보이는 곳)에 들어가지 않았다.
        for call in (get_call, patch_call):
            self.assertNotIn(SYNTHETIC_PASSWORD_B64, " ".join(call["argv"]))

    def test_apply_without_expected_context_is_rejected_and_every_call_carries_context(
        self,
    ) -> None:
        # 준비: context 없이 --apply → 거부, kubectl 호출 0회.
        rejected = self.run_tool("--apply", "--confirm", "mafest-api-db")
        self.assertEqual(rejected.returncode, 2)
        self.assertEqual(self.calls(), [])
        # 실행: context 를 주면 get·patch 두 호출 모두 같은 --context 를 달고 나간다.
        accepted = self.run_tool(
            "--apply", "--confirm", "mafest-api-db", "--expect-context", "ctx-test"
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual({call["context"] for call in self.calls()}, {"ctx-test"})

    def test_missing_source_key_stops_before_patch(self) -> None:
        result = self.run_tool(
            "--apply",
            "--confirm",
            "mafest-api-db",
            "--expect-context",
            "ctx-test",
            FAKE_KUBECTL_MODE="missing-key",
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual([call["argv"][0] for call in self.calls()], ["get"])

    def test_kubectl_error_text_is_not_forwarded(self) -> None:
        result = self.run_tool(
            "--apply",
            "--confirm",
            "mafest-api-db",
            "--expect-context",
            "ctx-test",
            FAKE_KUBECTL_MODE="fail",
        )
        self.assertEqual(result.returncode, 1)
        self.assert_no_secret_in(result)


if __name__ == "__main__":
    unittest.main()
