"""mafest_fault.py 를 가짜 kubectl로 시험한다. 실제 클러스터에는 접속하지 않는다.

가짜 kubectl은 상태 파일에 Pod 목록을 두고, 모든 호출(인자·표준입력·삭제 본문)을 로그에 남긴다.
삭제 본문의 preconditions 는 가짜 서버가 실제로 평가한다(틀리면 409).

검사하는 규칙
- 모든 호출에 승인 context 가 붙는다 / --offline 접속 0회 / --check 쓰기·exec 0회
- 삭제 조건 검증 기록이 없거나 낡았거나 실패면 --run 은 준비 안 됨(호출 0회)
- 주입 직전 재조회로 UID 가 바뀐 대상은 지우지 않고, 조건 불일치(409)는 재시도하지 않는다
- 측정이 깨지면 아직 보내지 않은 주입이 취소된다
- LLM 호출 근거: 표에 없는 경로·요청 종류 불일치·예산 초과·digest 불일치·근거 미기록은 시작하지 않는다
- vLLM 카운터가 늘면 실험을 무효로 표시한다

실행: python3 -I scripts/fault/test_mafest_fault.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "mafest_fault.py"
CONTEXT = "test-context"
TEST_NS = "mafest-fault-test-a"
DIGEST = "sha256:" + "ab" * 32

FAKE_KUBECTL = r"""#!/usr/bin/env python3
import json, os, sys, time, uuid
state_path, log_path = os.environ["FAKE_STATE"], os.environ["FAKE_LOG"]
argv = sys.argv[1:]
entry = {"argv": list(argv)}
state = json.load(open(state_path))
original = json.dumps(state, sort_keys=True)

def finish(code=0):
    with open(log_path, "a") as handle:
        handle.write(json.dumps(entry) + "\n")
    # 동시에 도는 가짜 프로세스끼리 상태 파일을 깨뜨리지 않도록, 바뀐 경우에만 원자적으로 교체한다.
    if json.dumps(state, sort_keys=True) != original:
        tmp = state_path + "." + str(os.getpid())
        json.dump(state, open(tmp, "w"))
        os.replace(tmp, state_path)
    sys.exit(code)

if argv[:1] == ["--context"]:
    context, args = argv[1], argv[2:]
    if context not in state["contexts"]:
        sys.stderr.write("error: context not found")
        finish(1)
else:
    context, args = None, argv

def pod_json(p):
    labels = {"cnpg.io/instanceRole": p["role"]} if p.get("role") else {"app.kubernetes.io/name": "mafest-api"}
    if p.get("vllm"):
        labels = {"app.kubernetes.io/name": "persona-vllm"}
    statuses = [{"name": "api", "imageID": "ghcr.io/x/app@" + p["digest"]}] if p.get("digest") else []
    if p.get("vllm"):
        statuses = [{"name": "vllm", "restartCount": p.get("restart_count", 0)}]
    return {"metadata": {"name": p["name"], "uid": p["uid"], "resourceVersion": p["rv"], "labels": labels},
            "spec": {"nodeName": p.get("node", ""),
                     "containers": [{"name": "api",
                                     "env": [{"name": k, "value": v} for k, v in p.get("env", {}).items()]
                                             + [{"name": n, "valueFrom": {"secretKeyRef": {"name": "x", "key": "y"}}} for n in p.get("value_from", [])],
                                     **({"envFrom": [{"configMapRef": {"name": "cfg"}}]} if p.get("env_from") else {})}]},
            "status": {"conditions": [{"type": "Ready", "status": "True" if p.get("ready", True) else "False"}],
                       "containerStatuses": statuses}}

def find(name):
    for group in ("db", "dummies"):
        for p in state[group]:
            if p["name"] == name:
                return group, p
    return None, None

verb = args[0]
if verb == "config":
    print("\n".join(state["contexts"]))
elif verb == "version":
    print(json.dumps({"clientVersion": {"gitVersion": "v1.30.0"},
                      "serverVersion": {"gitVersion": os.environ.get("FAKE_SERVER_VERSION", "v1.30.1")}}))
elif verb == "get" and args[1] == "pods":
    if "persona-inference" in args:
        state["vllm_pod_reads"] = state.get("vllm_pod_reads", 0) + 1
        reads = state["vllm_pod_reads"]
        mode = os.environ.get("FAKE_VLLM_POD_MODE", "ok")
        after = int(os.environ.get("FAKE_VLLM_POD_AFTER", "3"))
        pods = [dict(p) for p in state["vllm"]]
        if mode == "absent":
            pods = []
        elif mode == "notready":
            pods[0]["ready"] = False
        elif mode == "replace" and reads >= after:
            pods[0]["uid"] = "uid-vllm-new"
        elif mode == "restart" and reads >= after:
            pods[0]["restart_count"] = pods[0].get("restart_count", 0) + 1
        elif mode == "two" and reads >= after:
            pods.append({**pods[0], "name": "vllm-2", "uid": "uid-vllm-2"})
        elif mode == "get-fail-once" and reads == 2:
            sys.stderr.write("error")
            finish(1)
        print(json.dumps({"items": [pod_json(p) for p in pods]}))
    else:
        group = "api" if "mafest-app" in args else "db"
        print(json.dumps({"items": [pod_json(p) for p in state[group]]}))
elif verb == "get" and args[1] == "pod":
    name = args[2]
    _, pod = find(name)
    if "--ignore-not-found" in args:
        print("pod/" + name if pod else "")
    elif pod is None:
        sys.stderr.write("Error from server (NotFound)")
        finish(1)
    else:
        # uid 모드: 재조회 응답부터 같은 이름의 새 Pod(다른 UID)가 보인다.
        if name == "db-2" and os.environ.get("FAKE_RECREATE_ON_RECHECK") == "uid":
            pod["uid"] = "uid-db-2-recreated"
        print(json.dumps(pod_json(pod)))
        # rv 모드: 재조회 응답은 옛 resourceVersion 이고, 응답 직후 서버 값이 바뀐다.
        if name == "db-2" and os.environ.get("FAKE_RECREATE_ON_RECHECK") == "rv" and not state.get("bumped"):
            pod["rv"] = str(int(pod["rv"]) + 1)
            state["bumped"] = True
elif verb == "get" and args[1] == "namespace":
    if args[2] in state["namespaces"]:
        print("namespace/" + args[2])
    else:
        finish(1)
elif verb == "create":
    manifest = json.loads(sys.stdin.read())
    entry["manifest_kind"] = manifest["kind"]
    state["dummies"].append({"name": manifest["metadata"]["name"], "uid": "uid-" + uuid.uuid4().hex[:8], "rv": "100"})
elif verb == "delete" and args[1] == "--raw":
    path = args[2]
    name = path.rsplit("/", 1)[1]
    body = json.load(open(args[args.index("-f") + 1]))
    entry["body"] = body
    entry["raw_path"] = path
    if os.environ.get("FAKE_DELETE_MODE") == "fail":
        sys.stderr.write("Error from server (InternalError)")
        finish(1)
    group, pod = find(name)
    if pod is None:
        sys.stderr.write("Error from server (NotFound): pods not found")
        finish(1)
    pre = body.get("preconditions", {})
    ignore = os.environ.get("FAKE_IGNORE_PRECONDITIONS") == "1"
    if not ignore and (pre.get("uid") != pod["uid"] or pre.get("resourceVersion") != pod["rv"]):
        sys.stderr.write("Error from server (Conflict): Precondition failed")
        finish(1)
    if group == "db":
        for p in state["db"]:
            p["role"] = "replica" if p["role"] == "primary" else "primary"
    else:
        state["dummies"] = [p for p in state["dummies"] if p["name"] != name]
elif verb == "delete":
    name = args[2]
    group, pod = find(name)
    if group == "db":
        for p in state["db"]:
            p["role"] = "replica" if p["role"] == "primary" else "primary"
    elif group == "dummies":
        state["dummies"] = [p for p in state["dummies"] if p["name"] != name]
elif verb == "exec":
    if "-c" in args and "python3" in args and "-" in args[args.index("python3"):][:2]:
        sys.stdin.read()
        mode = os.environ.get("FAKE_PROBE_MODE", "normal")
        if mode == "garbage":
            print("this is not csv", flush=True)
            time.sleep(1.5)
        for seq in range(int(os.environ.get("FAKE_PROBE_LINES", "6"))):
            code = 503 if seq in (2, 3) else 200
            print(f"2026-01-01T00:00:0{seq}+00:00,{seq},{code},{20 + seq},", flush=True)
            time.sleep(0.1)
    elif "--version" in args:
        if os.environ.get("FAKE_PYTHON") == "missing":
            sys.stderr.write("exec: python3: not found")
            finish(127)
        print("Python 3.12.1")
    elif "python3" in args and "-c" in args:
        mode = os.environ.get("FAKE_VLLM_MODE", "ok")
        state["vllm_reads"] = state.get("vllm_reads", 0) + 1
        reads = state["vllm_reads"]
        if mode == "missing":
            print("MISSING")
        elif mode == "badexit":
            print(1000)  # 값처럼 보이지만 명령은 실패했다
            finish(1)
        elif mode in ("nan", "inf", "neg"):
            print({"nan": "nan", "inf": "inf", "neg": "-5"}[mode])
        elif mode == "increase" and reads >= 2:
            print(1005)
        elif mode == "decrease" and reads >= 2:
            print(0)
        elif mode == "fail-after" and reads >= 2:
            print(1000)
            finish(1)
        elif mode == "fail-once" and reads == 2:
            print(1000)
            finish(1)
        else:
            print(1000)
    elif "date" in args:
        print(f"{time.time():.3f}")
    else:
        print("42")
else:
    sys.exit(9)
finish(0)
"""

POD_ENV = {
    "LLM_USE_MOCK": "0",
    "MAFEST_LLM_MODEL": "model-under-test",
    "MAFEST_LLM_BASE_URL": "http://vllm.test:8000",
}
PRODUCT_PATH = "/v1/products/kr_etf/SYN0001"

BASE_STATE = {
    "contexts": [CONTEXT, "other-cluster"],
    "namespaces": [TEST_NS],
    "api": [
        {
            "name": "api-a",
            "uid": "uid-api-a",
            "rv": "11",
            "node": "worker1",
            "digest": DIGEST,
            "env": dict(POD_ENV),
        },
        {
            "name": "api-b",
            "uid": "uid-api-b",
            "rv": "12",
            "node": "worker2",
            "digest": DIGEST,
            "env": dict(POD_ENV),
        },
    ],
    "db": [
        {
            "name": "db-1",
            "uid": "uid-db-1",
            "rv": "21",
            "node": "worker1",
            "role": "replica",
        },
        {
            "name": "db-2",
            "uid": "uid-db-2",
            "rv": "22",
            "node": "worker2",
            "role": "primary",
        },
    ],
    "dummies": [],
    "vllm": [
        {
            "name": "vllm-1",
            "uid": "uid-vllm-1",
            "rv": "31",
            "node": "gpu1",
            "vllm": True,
            "restart_count": 0,
        }
    ],
}
VALID_INPUTS = {
    "method": "GET",
    "request_kind": "db_read_only",
    "path": PRODUCT_PATH,
    "interval_s": 0.1,
    "duration_s": 0.6,
    "inject_after_s": 0.2,
    "request_timeout_s": 5,
    "gpu_call_cap": 0,
    "abort_after_consecutive_failures": 100,
    "recovery_timeout_s": 3,
    "llm_counter_poll_s": 0.1,
}


def make_basis() -> dict:
    """증명된 상세 조회 경로와, 도달 가능해서 상한이 null 인 검색 경로를 가진 합성 표."""
    proof = {
        "reviewed_commit": "0" * 40,
        "api_image_digest": DIGEST,
        "provenance_verified": False,
        "entrypoint": "합성 진입점",
        "call_chain": ["합성 호출 경로"],
        "branches": ["합성 분기"],
        "settings_dependency": "없음",
    }
    return {
        "routes": {
            "/v1/products/{domain}/{product_id}": {
                "method": "GET",
                "request_kind": "db_read_only",
                "llm_call_upper_bound": 0,
                "proof": dict(proof),
            },
            "/v1/search": {
                "method": "POST",
                "request_kind": "end_to_end_search",
                "llm_call_upper_bound": None,
                "proof": dict(proof),
            },
        }
    }


def load_tool_module():
    spec = importlib.util.spec_from_file_location("mafest_fault_under_test", TOOL)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FaultToolTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.log = self.dir / "calls.jsonl"
        self.state = self.dir / "state.json"
        self.inputs = self.dir / "inputs.json"
        self.basis = self.dir / "basis.json"
        self.verification = self.dir / "verification.json"
        self.inputs.write_text(json.dumps(VALID_INPUTS))
        self.basis.write_text(json.dumps(make_basis()))
        self.write_verification()
        fake = self.dir / "kubectl"
        fake.write_text(FAKE_KUBECTL)
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.state.write_text(json.dumps(BASE_STATE))
        self.env = {
            **os.environ,
            "MAFEST_KUBECTL": str(fake),
            "FAKE_STATE": str(self.state),
            "FAKE_LOG": str(self.log),
        }

    # --- 도우미 ---
    def write_verification(self, **overrides: object) -> None:
        record = {
            "kind": "mafest-delete-precondition-verification",
            "context": CONTEXT,
            "test_namespace": TEST_NS,
            "verified_utc": datetime.now(timezone.utc).isoformat(),
            "versions": {"client": "v1.30.0", "server": "v1.30.1"},
            "cases": {},
            "passed": True,
        }
        record.update(overrides)
        self.verification.write_text(json.dumps(record))

    def tool(self, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(TOOL), *args],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def verbs(self) -> list[str]:
        return [c["argv"][2] for c in self.calls()]

    def raw_deletes(self) -> list[dict]:
        return [c for c in self.calls() if "raw_path" in c]

    def delete_calls(self) -> list[dict]:
        return [c for c in self.calls() if c["argv"][2] == "delete"]

    def summary(self) -> dict:
        return json.loads((self.dir / "out/summary.json").read_text())

    def run_args(self, **overrides: str | None) -> list[str]:
        values: dict[str, str | None] = {
            "--run": "E0",
            "--confirm": "E0",
            "--expect-context": CONTEXT,
            "--target-uid": "uid-db-2",
            "--inputs": str(self.inputs),
            "--out-dir": str(self.dir / "out"),
            "--llm-basis": str(self.basis),
            "--delete-verification": str(self.verification),
        }
        values.update(overrides)
        return [item for pair in values.items() if pair[1] is not None for item in pair]

    # --- context ---
    def test_every_call_carries_approved_context_in_check_and_run(self) -> None:
        self.tool("--check", "--expect-context", CONTEXT)
        self.tool(*self.run_args())
        calls = self.calls()
        self.assertGreater(len(calls), 10)
        for call in calls:
            self.assertEqual(call["argv"][:2], ["--context", CONTEXT], call)

    def test_unknown_context_stops_before_reading_pods(self) -> None:
        result = self.tool("--check", "--expect-context", "missing-context")
        self.assertEqual(result.returncode, 4)
        self.assertNotIn("get", self.verbs()[1:])

    def test_wrapper_adds_context_and_refuses_debug(self) -> None:
        module = load_tool_module()
        kubectl = module.Kubectl("ctx", frozenset({"get"}))
        self.assertEqual(kubectl.argv(["get", "pods"])[1:3], ["--context", "ctx"])
        with self.assertRaises(module.ForbiddenCall):
            kubectl.argv(["debug", "pod"])

    # --- offline / check ---
    def test_offline_makes_no_kubectl_call(self) -> None:
        result = self.tool("--offline")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_check_only_reads_and_reports_target_identity(self) -> None:
        result = self.tool("--check", "--expect-context", CONTEXT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(self.verbs()), {"config", "get"})
        self.assertIn("uid-db-2", result.stdout)
        self.assertIn("api-a", result.stdout)

    # --- 삭제 방식과 대상 재확인 ---
    def test_run_sends_one_delete_with_uid_and_resource_version_preconditions(
        self,
    ) -> None:
        result = self.tool(*self.run_args())
        self.assertEqual(result.returncode, 0, result.stderr)
        deletes = self.raw_deletes()
        self.assertEqual(len(deletes), 1)
        self.assertEqual(
            deletes[0]["raw_path"], "/api/v1/namespaces/mafest-data/pods/db-2"
        )
        self.assertEqual(
            deletes[0]["body"]["preconditions"],
            {"uid": "uid-db-2", "resourceVersion": "22"},
        )
        self.assertEqual(self.summary()["fault"]["requests_sent"], 1)
        self.assertNotIn("debug", self.verbs())

    def test_pod_recreated_with_new_uid_before_injection_is_not_deleted(self) -> None:
        # 첫 get(사전 점검)은 승인 UID, 주입 직전 재조회에서는 같은 이름의 새 Pod(다른 UID)가 보이는 상황.
        self.tool(*self.run_args(), FAKE_RECREATE_ON_RECHECK="uid")
        self.assertEqual(self.delete_calls(), [])
        self.assertIn("주입 취소", self.summary()["fault"]["result"])

    def test_precondition_conflict_is_not_retried(self) -> None:
        # 재조회 뒤 서버에서 resourceVersion 이 바뀐 상황 → 409. 다시 보내지 않는다.
        self.tool(*self.run_args(), FAKE_RECREATE_ON_RECHECK="rv")
        self.assertEqual(len(self.delete_calls()), 1)
        self.assertIn("409", self.summary()["fault"]["result"])
        primary = [
            p
            for p in json.loads(self.state.read_text())["db"]
            if p["role"] == "primary"
        ]
        self.assertEqual(primary[0]["name"], "db-2")  # 아무것도 지워지지 않았다

    def test_failed_delete_response_is_not_retried(self) -> None:
        self.tool(*self.run_args(), FAKE_DELETE_MODE="fail")
        self.assertEqual(len(self.delete_calls()), 1)

    def test_stale_target_uid_argument_calls_no_write(self) -> None:
        result = self.tool(*self.run_args(**{"--target-uid": "uid-db-1"}))
        self.assertEqual(result.returncode, 4)
        self.assertEqual(self.delete_calls(), [])
        self.assertNotIn("exec", self.verbs())

    # --- 측정 중단 시 주입 취소 ---
    def test_garbled_probe_output_cancels_pending_injection(self) -> None:
        self.inputs.write_text(
            json.dumps({**VALID_INPUTS, "inject_after_s": 0.5, "duration_s": 1.0})
        )
        self.tool(*self.run_args(), FAKE_PROBE_MODE="garbage")
        self.assertEqual(self.delete_calls(), [])
        summary = self.summary()
        self.assertTrue(summary["aborted"])
        self.assertEqual(summary["fault"]["requests_sent"], 0)

    # --- 검증 기록 게이트 ---
    def test_missing_verification_record_blocks_run_without_any_call(self) -> None:
        self.verification.unlink()
        result = self.tool(*self.run_args())
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.calls(), [])

    def test_stale_or_foreign_verification_blocks_run(self) -> None:
        old = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
        self.write_verification(verified_utc=old)
        self.assertEqual(self.tool(*self.run_args()).returncode, 3)
        self.write_verification(context="other-cluster")
        self.assertEqual(self.tool(*self.run_args()).returncode, 3)
        self.assertEqual(self.calls(), [])

    def test_failed_verification_stops_run_and_has_no_name_delete_bypass(self) -> None:
        # 검증이 통과하지 않았으면 중단한다. 이름 삭제로 우회하는 옵션도 없다(알 수 없는 인자 → 사용법 오류).
        self.write_verification(passed=False)
        self.assertEqual(self.tool(*self.run_args()).returncode, 3)
        bypass = self.tool(*self.run_args(), "--accept-name-delete-race")
        self.assertEqual(bypass.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_run_mode_guard_refuses_delete_by_name(self) -> None:
        module = load_tool_module()
        with self.assertRaises(module.ForbiddenCall):
            module.run_mode_guard(["delete", "pod", "db-2", "-n", "mafest-data"])

    def test_version_change_since_verification_blocks_before_any_write(self) -> None:
        result = self.tool(*self.run_args(), FAKE_SERVER_VERSION="v1.31.0")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.delete_calls(), [])
        self.assertNotIn("exec", self.verbs())

    def test_blocked_experiment_ids_are_not_run(self) -> None:
        for experiment_id in ("E1", "E2", "E3", "E4", "E5"):
            with self.subTest(experiment_id=experiment_id):
                result = self.tool(
                    *self.run_args(
                        **{"--run": experiment_id, "--confirm": experiment_id}
                    )
                )
                self.assertEqual(result.returncode, 3)
        self.assertEqual(self.calls(), [])

    def test_confirm_mismatch_calls_nothing(self) -> None:
        self.assertEqual(self.tool(*self.run_args(**{"--confirm": "E1"})).returncode, 2)
        self.assertEqual(self.calls(), [])

    # --- LLM 호출 상한: 코드로 증명된 경로만 ---
    def edit_route(self, pattern: str, **changes: object) -> None:
        basis = make_basis()
        basis["routes"][pattern].update(changes)
        self.basis.write_text(json.dumps(basis))

    def test_search_route_with_reachable_llm_is_rejected(self) -> None:
        # /v1/search 는 LLM 호출 지점에 도달할 수 있어 상한이 null 이다 → 어떤 입력으로도 시작하지 않는다.
        self.inputs.write_text(
            json.dumps(
                {
                    **VALID_INPUTS,
                    "method": "POST",
                    "request_kind": "end_to_end_search",
                    "path": "/v1/search",
                    "body": {"question": "합성 질문"},
                    "gpu_call_cap": 100000,
                }
            )
        )
        self.assertEqual(self.tool(*self.run_args()).returncode, 4)
        self.assertEqual(self.calls(), [])

    def test_stream_route_not_in_table_is_rejected(self) -> None:
        self.inputs.write_text(
            json.dumps({**VALID_INPUTS, "method": "POST", "path": "/v1/search/stream"})
        )
        self.assertEqual(self.tool(*self.run_args()).returncode, 4)
        self.assertEqual(self.calls(), [])

    def test_method_or_request_kind_mismatch_is_rejected(self) -> None:
        for change in ({"method": "POST"}, {"request_kind": "end_to_end_search"}):
            with self.subTest(change=change):
                self.inputs.write_text(json.dumps({**VALID_INPUTS, **change}))
                self.assertEqual(self.tool(*self.run_args()).returncode, 4)
        self.assertEqual(self.calls(), [])

    def test_path_with_query_or_other_shape_is_rejected(self) -> None:
        for path in (PRODUCT_PATH + "?x=1", "/v1/products/etf", "/v1/products/etf/a/b"):
            with self.subTest(path=path):
                self.inputs.write_text(json.dumps({**VALID_INPUTS, "path": path}))
                self.assertEqual(self.tool(*self.run_args()).returncode, 4)
        self.assertEqual(self.calls(), [])

    def test_incomplete_proof_is_not_accepted(self) -> None:
        pattern = "/v1/products/{domain}/{product_id}"
        for field in (
            "call_chain",
            "branches",
            "entrypoint",
            "settings_dependency",
            "reviewed_commit",
        ):
            with self.subTest(field=field):
                basis = make_basis()
                basis["routes"][pattern]["proof"][field] = (
                    [] if field in ("call_chain", "branches") else ""
                )
                self.basis.write_text(json.dumps(basis))
                self.assertEqual(self.tool(*self.run_args()).returncode, 4)
        basis = make_basis()
        basis["routes"][pattern]["proof"]["api_image_digest"] = None
        self.basis.write_text(json.dumps(basis))
        self.assertEqual(self.tool(*self.run_args()).returncode, 4)
        self.assertEqual(self.calls(), [])

    def test_budget_uses_proven_upper_bound_not_observation(self) -> None:
        # 증명된 상한이 2회이면 6건 × 2회 = 12 > 상한 0 → 거부. 과거에 0회였다는 관측은 개입하지 않는다.
        self.edit_route("/v1/products/{domain}/{product_id}", llm_call_upper_bound=2)
        self.assertEqual(self.tool(*self.run_args()).returncode, 4)
        self.assertEqual(self.calls(), [])

    def test_gpu_call_cap_above_proven_budget_is_rejected_as_misinput(self) -> None:
        # 상품 상세의 증명된 상한은 0 이므로 cap 은 0 만 허용된다. 더 크게 적으면 감시 기준이 느슨해진다.
        for cap in (1, 5, 100000):
            with self.subTest(cap=cap):
                self.inputs.write_text(
                    json.dumps({**VALID_INPUTS, "gpu_call_cap": cap})
                )
                self.assertEqual(self.tool(*self.run_args()).returncode, 4)
        self.assertEqual(self.calls(), [])

    def test_gpu_call_cap_equal_to_proven_budget_is_accepted(self) -> None:
        # 증명된 상한이 2회이고 계획 요청이 5건(0.6초 ÷ 0.1초, 소수점 버림)이면 예산 10 → cap 10 만 맞다.
        self.edit_route("/v1/products/{domain}/{product_id}", llm_call_upper_bound=2)
        self.inputs.write_text(json.dumps({**VALID_INPUTS, "gpu_call_cap": 10}))
        module = load_tool_module()
        routes = module.load_llm_basis(self.basis)
        inputs, proof = module.load_e0_inputs(self.inputs, routes)
        self.assertEqual((inputs.gpu_call_cap, proof.llm_call_upper_bound), (10, 2))

    def test_abort_window_shorter_than_recovery_timeout_is_rejected(self) -> None:
        # 10회 × 0.1초 = 1초 < recovery_timeout_s 3초: 복구를 기다리기도 전에 측정을 접는 설정이다.
        self.inputs.write_text(
            json.dumps({**VALID_INPUTS, "abort_after_consecutive_failures": 10})
        )
        result = self.tool(*self.run_args())
        self.assertEqual(result.returncode, 4)
        self.assertIn("recovery_timeout_s", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_abort_window_equal_to_recovery_timeout_is_accepted(self) -> None:
        # 240회 × 0.5초 = 120초 = recovery_timeout_s 120초 (예시 파일의 값)
        module = load_tool_module()
        example = json.loads((TOOL.parent / "e0-inputs.example.json").read_text())
        example["path"] = PRODUCT_PATH
        self.inputs.write_text(json.dumps(example))
        routes = module.load_llm_basis(self.basis)
        inputs, _proof = module.load_e0_inputs(self.inputs, routes)
        self.assertEqual(
            inputs.abort_after_consecutive_failures * inputs.interval_s,
            inputs.recovery_timeout_s,
        )

    def test_inert_abort_rule_is_warned_not_rejected(self) -> None:
        module = load_tool_module()
        routes = module.load_llm_basis(self.basis)
        inputs, _proof = module.load_e0_inputs(
            self.inputs, routes
        )  # 10초 > 주입 뒤 남은 0.4초
        self.assertTrue(any("비활성" in w for w in module.input_warnings(inputs)))
        check = self.tool(
            "--check",
            "--expect-context",
            CONTEXT,
            "--inputs",
            str(self.inputs),
            "--llm-basis",
            str(self.basis),
        )
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertIn("경고", check.stderr)

    def test_running_api_digest_different_from_proof_invalidates_it(self) -> None:
        state = json.loads(self.state.read_text())
        state["api"][1]["digest"] = "sha256:" + "cd" * 32
        self.state.write_text(json.dumps(state))
        result = self.tool(*self.run_args())
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.delete_calls(), [])
        self.assertNotIn("exec", self.verbs())

    # --- envFrom·valueFrom 은 확인 불가로 차단 ---
    def set_api_pod(self, **changes: object) -> None:
        state = json.loads(self.state.read_text())
        state["api"][0].update(changes)
        self.state.write_text(json.dumps(state))

    def test_env_from_makes_settings_unverifiable_and_blocks(self) -> None:
        self.set_api_pod(env_from=True)
        result = self.tool(*self.run_args())
        self.assertEqual(result.returncode, 3)
        self.assertIn("envFrom", result.stderr)
        self.assertEqual(self.delete_calls(), [])
        self.assertNotIn("exec", self.verbs())

    def test_value_from_on_monitored_setting_blocks_but_unrelated_value_from_does_not(
        self,
    ) -> None:
        self.set_api_pod(value_from=["MAFEST_LLM_SUMMARY"])
        self.assertEqual(self.tool(*self.run_args()).returncode, 3)
        self.assertEqual(self.delete_calls(), [])
        self.set_api_pod(value_from=["PGURL"])  # 설정과 무관한 비밀 참조는 막지 않는다
        self.assertEqual(
            self.tool(
                *self.run_args(**{"--out-dir": str(self.dir / "out2")})
            ).returncode,
            0,
        )

    # --- vLLM 카운터: 읽기 검증 ---
    def test_counter_read_failures_and_nonfinite_values_block_start(self) -> None:
        # 종료 코드 실패(숫자 stdout 이어도), 지표 없음, nan/inf/음수 는 모두 시작 전에 거부한다.
        for mode in ("badexit", "missing", "nan", "inf", "neg"):
            with self.subTest(mode=mode):
                result = self.tool(
                    *self.run_args(**{"--out-dir": str(self.dir / f"out-{mode}")}),
                    FAKE_VLLM_MODE=mode,
                )
                self.assertEqual(result.returncode, 3, result.stderr)
                self.state.write_text(json.dumps(BASE_STATE))
        self.assertEqual(self.delete_calls(), [])

    # --- vLLM 카운터: 측정 중 주기 확인 ---
    def test_mid_run_counter_increase_stops_measurement_and_cancels_injection(
        self,
    ) -> None:
        self.inputs.write_text(
            json.dumps(
                {
                    **VALID_INPUTS,
                    "inject_after_s": 1.5,
                    "duration_s": 3.0,
                    "llm_counter_poll_s": 0.1,
                }
            )
        )
        self.tool(*self.run_args(), FAKE_VLLM_MODE="increase", FAKE_PROBE_LINES="30")
        summary = self.summary()
        self.assertEqual(self.delete_calls(), [])
        self.assertEqual(summary["fault"]["requests_sent"], 0)
        self.assertTrue(summary["aborted"])
        self.assertEqual(summary["verdict"], "무효 표시")

    def test_mid_run_counter_decrease_is_treated_as_discontinuity(self) -> None:
        self.inputs.write_text(
            json.dumps(
                {
                    **VALID_INPUTS,
                    "inject_after_s": 1.5,
                    "duration_s": 3.0,
                    "llm_counter_poll_s": 0.1,
                }
            )
        )
        self.tool(*self.run_args(), FAKE_VLLM_MODE="decrease", FAKE_PROBE_LINES="30")
        summary = self.summary()
        self.assertEqual(self.delete_calls(), [])
        self.assertTrue(summary["aborted"])
        self.assertEqual(summary["verdict"], "무효 표시")
        self.assertTrue(any("감소" in reason for reason in summary["invalid_reasons"]))

    def test_end_of_run_counter_decrease_marks_invalid_even_without_polling(
        self,
    ) -> None:
        # 중간 폴링이 닿지 않는 긴 주기에서도 사후 값이 사전 값보다 작으면(1000→0) 무효 표시다.
        self.inputs.write_text(json.dumps({**VALID_INPUTS, "llm_counter_poll_s": 100}))
        self.tool(*self.run_args(), FAKE_VLLM_MODE="decrease")
        self.assertEqual(self.summary()["verdict"], "무효 표시")

    def test_repeated_mid_run_read_failures_stop_measurement(self) -> None:
        self.inputs.write_text(
            json.dumps(
                {
                    **VALID_INPUTS,
                    "inject_after_s": 1.5,
                    "duration_s": 3.0,
                    "llm_counter_poll_s": 0.1,
                }
            )
        )
        self.tool(*self.run_args(), FAKE_VLLM_MODE="fail-after", FAKE_PROBE_LINES="30")
        summary = self.summary()
        self.assertEqual(self.delete_calls(), [])
        self.assertTrue(summary["aborted"])
        self.assertEqual(summary["verdict"], "무효 표시")

    def test_single_mid_run_read_failure_is_recorded_as_unknown_but_does_not_stop(
        self,
    ) -> None:
        self.inputs.write_text(json.dumps({**VALID_INPUTS, "llm_counter_poll_s": 0.1}))
        self.tool(*self.run_args(), FAKE_VLLM_MODE="fail-once")
        summary = self.summary()
        self.assertFalse(summary["aborted"])
        self.assertEqual(
            summary["verdict"], "무효 표시"
        )  # 미확인 구간이 있으면 수치 기록만으로 두지 않는다
        self.assertEqual(summary["fault"]["requests_sent"], 1)

    def test_missing_python3_in_measurement_container_blocks_before_any_injection(
        self,
    ) -> None:
        result = self.tool(*self.run_args(), FAKE_PYTHON="missing")
        self.assertEqual(result.returncode, 3)
        self.assertIn("python3", result.stderr)
        self.assertEqual(self.delete_calls(), [])

    def test_python_version_is_checked_in_mafest_api_container_before_counter_read(
        self,
    ) -> None:
        self.tool(*self.run_args())
        execs = [c["argv"] for c in self.calls() if c["argv"][2] == "exec"]
        self.assertIn("--version", execs[0])  # 첫 exec 가 python3 확인이다
        self.assertEqual(
            execs[0][execs[0].index("-c") + 1], "api"
        )  # netshoot 등이 아닌 mafest-api 컨테이너
        self.assertEqual(self.summary()["measurement_python"], "Python 3.12.1")

    # --- vLLM Pod 신원(UID·재시작 횟수) ---
    def long_run_inputs(self, **overrides: object) -> None:
        self.inputs.write_text(
            json.dumps(
                {
                    **VALID_INPUTS,
                    "inject_after_s": 1.5,
                    "duration_s": 3.0,
                    "llm_counter_poll_s": 0.1,
                    **overrides,
                }
            )
        )

    def test_check_prints_vllm_pod_uid_and_restart_count(self) -> None:
        result = self.tool("--check", "--expect-context", CONTEXT)
        self.assertIn("uid-vllm-1", result.stdout)
        self.assertIn("재시작=0", result.stdout)

    def test_run_records_vllm_pod_identity_in_plan_and_summary(self) -> None:
        self.tool(*self.run_args())
        plan = json.loads((self.dir / "out/plan.json").read_text())
        self.assertEqual(plan["vllm_pod"]["uid"], "uid-vllm-1")
        pod = self.summary()["vllm_pod"]
        self.assertFalse(pod["changed"])
        self.assertEqual(pod["before"]["uid"], pod["after"]["uid"])

    def test_vllm_pod_missing_or_not_ready_blocks_start(self) -> None:
        for mode in ("absent", "notready"):
            with self.subTest(mode=mode):
                result = self.tool(
                    *self.run_args(**{"--out-dir": str(self.dir / f"out-{mode}")}),
                    FAKE_VLLM_POD_MODE=mode,
                )
                self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.delete_calls(), [])

    def test_check_fails_when_vllm_pod_is_not_unique_or_not_ready(self) -> None:
        self.assertEqual(
            self.tool(
                "--check", "--expect-context", CONTEXT, FAKE_VLLM_POD_MODE="absent"
            ).returncode,
            4,
        )
        self.assertEqual(
            self.tool(
                "--check", "--expect-context", CONTEXT, FAKE_VLLM_POD_MODE="notready"
            ).returncode,
            3,
        )

    def test_vllm_pod_uid_change_stops_even_if_counter_did_not_decrease(self) -> None:
        # 카운터는 그대로(감소 아님)인데 Pod UID 만 바뀐 상황 → 감소 검사로는 못 잡는다. UID 로 중단해야 한다.
        self.long_run_inputs()
        self.tool(*self.run_args(), FAKE_VLLM_POD_MODE="replace", FAKE_PROBE_LINES="30")
        summary = self.summary()
        self.assertEqual(self.delete_calls(), [])
        self.assertTrue(summary["aborted"])
        self.assertIn("Pod", summary["abort_reason"])
        self.assertTrue(summary["vllm_pod"]["changed"])
        self.assertEqual(summary["verdict"], "무효 표시")
        self.assertEqual(
            summary["vllm_counter"]["after"], 1000.0
        )  # 카운터는 이전 값 이상이었다

    def test_vllm_container_restart_count_change_also_stops(self) -> None:
        self.long_run_inputs()
        self.tool(*self.run_args(), FAKE_VLLM_POD_MODE="restart", FAKE_PROBE_LINES="30")
        summary = self.summary()
        self.assertEqual(self.delete_calls(), [])
        self.assertTrue(summary["vllm_pod"]["changed"])

    def test_vllm_pod_turning_into_two_pods_is_treated_as_discontinuity(self) -> None:
        self.long_run_inputs()
        self.tool(*self.run_args(), FAKE_VLLM_POD_MODE="two", FAKE_PROBE_LINES="30")
        summary = self.summary()
        self.assertEqual(self.delete_calls(), [])
        self.assertTrue(summary["aborted"])
        self.assertEqual(summary["verdict"], "무효 표시")

    def test_identity_change_between_polls_is_caught_by_final_comparison(self) -> None:
        # 중간 폴링이 닿지 않아도(긴 주기) 사후 비교에서 UID 변경이 드러나 무효 표시가 된다.
        self.inputs.write_text(json.dumps({**VALID_INPUTS, "llm_counter_poll_s": 100}))
        self.tool(
            *self.run_args(), FAKE_VLLM_POD_MODE="replace", FAKE_VLLM_POD_AFTER="2"
        )
        summary = self.summary()
        self.assertTrue(summary["vllm_pod"]["changed"])
        self.assertEqual(summary["verdict"], "무효 표시")

    def test_single_pod_read_failure_mid_run_is_unknown_not_discontinuity(self) -> None:
        self.inputs.write_text(json.dumps({**VALID_INPUTS, "llm_counter_poll_s": 0.1}))
        self.tool(*self.run_args(), FAKE_VLLM_POD_MODE="get-fail-once")
        summary = self.summary()
        self.assertFalse(summary["aborted"])
        self.assertFalse(summary["vllm_pod"]["changed"])
        self.assertEqual(summary["verdict"], "무효 표시")  # 미확인 구간이 생겼으므로

    def test_check_only_placeholder_id_is_refused_for_run_but_passes_check(
        self,
    ) -> None:
        self.inputs.write_text(
            json.dumps(
                {**VALID_INPUTS, "path": "/v1/products/kr_etf/CHECK-ONLY-PLACEHOLDER"}
            )
        )
        check = self.tool(
            "--check",
            "--expect-context",
            CONTEXT,
            "--inputs",
            str(self.inputs),
            "--llm-basis",
            str(self.basis),
        )
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertIn("증명 유효", check.stdout)
        self.assertEqual(self.raw_deletes(), [])
        self.assertEqual(self.tool(*self.run_args()).returncode, 4)

    def test_run_and_check_record_tool_and_basis_file_hashes(self) -> None:
        import hashlib

        module_hash = hashlib.sha256(TOOL.read_bytes()).hexdigest()
        basis_hash = hashlib.sha256(self.basis.read_bytes()).hexdigest()
        self.tool(*self.run_args())
        tool = json.loads((self.dir / "out/plan.json").read_text())["tool"]
        self.assertEqual(tool["mafest_fault_py_sha256"], module_hash)
        self.assertEqual(tool["llm_call_basis_json_sha256"], basis_hash)
        check = self.tool(
            "--check", "--expect-context", CONTEXT, "--llm-basis", str(self.basis)
        )
        self.assertIn(module_hash, check.stdout)

    def test_db_observation_reads_the_mafest_database_not_the_default_one(self) -> None:
        self.tool(*self.run_args())
        psql = [c["argv"] for c in self.calls() if "psql" in c["argv"]]
        self.assertTrue(psql)
        for argv in psql:
            self.assertEqual(argv[argv.index("-d") + 1], "mafest")

    def test_unchanged_counter_keeps_numbers_only_verdict(self) -> None:
        self.tool(*self.run_args())
        self.assertIn("수치 기록만", self.summary()["verdict"])
        self.assertEqual(self.summary()["requests"]["failures"], 2)

    def test_traffic_premise_is_shown_in_offline_check_and_run(self) -> None:
        self.assertIn("LLM 요청이 없어야", self.tool("--offline").stdout)
        self.assertIn(
            "LLM 요청이 없어야",
            self.tool("--check", "--expect-context", CONTEXT).stdout,
        )
        self.assertIn("LLM 요청이 없어야", self.tool(*self.run_args()).stderr)

    # --- 삭제 조건 검증 모드 ---
    def verify_args(self, **overrides: str | None) -> list[str]:
        values: dict[str, str | None] = {
            "--verify-delete": "",
            "--expect-context": CONTEXT,
            "--test-namespace": TEST_NS,
            "--confirm": TEST_NS,
            "--verification-out": str(self.dir / "new-verification.json"),
        }
        values.update(overrides)
        out: list[str] = []
        for key, value in values.items():
            if value is None:
                continue
            out.append(key)
            if value != "":
                out.append(value)
        return out

    def test_verify_delete_checks_three_cases_and_cleans_up_dummies(self) -> None:
        result = self.tool(*self.verify_args())
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads((self.dir / "new-verification.json").read_text())
        self.assertTrue(record["passed"])
        self.assertEqual(record["cases"]["wrong_uid"]["observed"], "conflict")
        self.assertEqual(
            record["cases"]["wrong_resource_version"]["observed"], "conflict"
        )
        self.assertEqual(record["cases"]["correct"]["observed"], "accepted")
        self.assertEqual(json.loads(self.state.read_text())["dummies"], [])
        # 운영 네임스페이스는 한 번도 건드리지 않았다.
        for call in self.calls():
            text = json.dumps(call)
            self.assertNotIn("mafest-data", text)
            self.assertNotIn("mafest-app", text)

    def test_verify_delete_records_failure_when_server_ignores_conditions(self) -> None:
        result = self.tool(*self.verify_args(), FAKE_IGNORE_PRECONDITIONS="1")
        self.assertEqual(result.returncode, 4)
        record = json.loads((self.dir / "new-verification.json").read_text())
        self.assertFalse(record["passed"])
        self.assertEqual(json.loads(self.state.read_text())["dummies"], [])
        # 실패한 기록으로는 DB 대상 --run 이 준비 안 됨으로 남는다.
        self.verification.write_text((self.dir / "new-verification.json").read_text())
        self.assertEqual(self.tool(*self.run_args()).returncode, 3)

    def test_verify_delete_refuses_non_test_namespace_without_calls(self) -> None:
        result = self.tool(
            *self.verify_args(
                **{"--test-namespace": "mafest-data", "--confirm": "mafest-data"}
            )
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
