"""mafest 장애 시험 도구. 한 번 실행에 장애를 최대 한 번(ID별 상한) 넣고 같은 형식으로 기록한다.

이 도구는 로컬 준비물이다. 지금까지 가짜 kubectl로만 시험했고 실제 클러스터에 실행하지 않았다.

모드
- 기본 / --offline : 계획·판정 기준을 출력한다. kubectl을 호출하지 않는다.
- --check          : 읽기 전용 사전 점검(get, config, version). exec·delete·debug를 쓰지 않는다.
- --verify-delete  : 삭제 조건(UID·resourceVersion) 본문이 서버에서 실제로 지켜지는지 테스트 네임스페이스의
                     더미 Pod로 세 경우(틀린 UID / 틀린 resourceVersion / 정상)를 검증하고 기록을 남긴다.
- --run <ID>       : ID·대상 UID·통과한 검증 기록이 모두 맞을 때만, 사전 점검을 다시 통과한 뒤 장애를 넣고
                     측정한다. 실패해도 자동 재시도·다음 ID 연속 실행은 없다. 검증이 통과하지 않았으면 중단하며
                     이름 삭제 같은 우회 경로는 없다.

설계 원칙
- 모든 kubectl 호출은 Kubectl 래퍼 한 곳을 지나며 `--context <승인값>`이 항상 붙는다.
- 장애 대상은 context·namespace·이름·UID·노드·CNPG 역할로 고정하고, 주입 직전에 다시 읽어 확인한다.
- 삭제 요청은 `kubectl delete --raw` + DeleteOptions 본문의 preconditions(uid, resourceVersion)로 보낸다.
  조건이 어긋나 409가 오면 다시 보내지 않고 주입을 취소한다. 같은 이름으로 재생성된 다른 Pod는 지워지지 않는다.
  resourceVersion은 Pod 상태가 바뀌어도 달라지므로, 정상 상황의 409도 "주입 취소"로 기록할 뿐 시험 실패가 아니다.
- Pod 강제 삭제(grace-period=0)는 프로세스 종료·fencing 보장이 아니다. 기록에도 "강제 삭제 요청"이라고만 쓴다.
- 장애 요청 응답이 유실되면 "미확인"으로 기록하고 다시 보내지 않는다.
- 어떤 오류로든 측정이 중단되면 아직 보내지 않은 장애 주입은 취소된다(finally + 주입 직전 락 안의 검사).
- 측정은 장애 대상과 다른 노드의 기존 api Pod에서 `kubectl exec`로 한다. 이 도구는 운영 Pod/ephemeral container를 만들지 않는다.
- 요청 경로별 LLM 호출 상한은 관측값이 아니라 "코드로 증명한 것"만 쓴다. llm-call-basis.json 의 증명(이미지 digest·
  검토 커밋·진입점·호출 경로·분기 조건·설정 의존)이 완전하고 지금 실행 중인 api digest가 같을 때만 예산에 쓴다.
  digest가 바뀌거나 envFrom·valueFrom 때문에 설정을 확인할 수 없으면 시작하지 않는다. LLM 호출 지점에 도달할 수
  있는 경로(/v1/search 등)는 상한이 정해지지 않아 거부한다. 표에 없는 경로도 거부한다.
- 시작할 때 vLLM Pod(정확히 1개, Ready)의 UID·재시작 횟수를 기록하고, 측정 중 바뀌거나 Pod가 하나로 특정되지 않으면
  카운터 값과 무관하게 관측 불연속으로 중단한다.
- 측정 중에는 vLLM 카운터를 주기적으로 읽어 증가량이 상한을 넘거나 값이 줄거나 읽기가 반복 실패하면 측정을
  멈추고 아직 안 보낸 주입을 취소한다. 이것은 피해 한도일 뿐 호출을 막지는 못한다. 카운터는 엔진 전체 값이라
  측정 중 다른 LLM 요청이 없어야 한다(OTHER_LLM_TRAFFIC_NOTICE).
- 비밀번호·연결 문자열·질문/응답 본문은 기록하지 않는다. 요청 본문은 입력 파일의 합성 값만 쓴다.
- 판정 기준은 아래 EXPERIMENTS에 고정돼 있고 결과를 본 뒤 바꾸지 않는다.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

APP_NAMESPACE = "mafest-app"
DATA_NAMESPACE = "mafest-data"
API_SELECTOR = "app.kubernetes.io/name=mafest-api"
DB_SELECTOR = "cnpg.io/cluster=mafest-db"
# CNPG initdb 가 만든 앱 데이터베이스(kustomize/base/mafest-db/cluster.yaml 의 bootstrap.initdb.database).
# psql 에 -d 를 주지 않으면 기본 DB(postgres)에 붙어 pg_stat 집계가 엉뚱한 DB 것이 된다.
DB_NAME = "mafest"
API_CONTAINER = "api"
# CNPG가 인스턴스 Pod에 붙이는 역할 라벨. 버전에 따라 이름이 달라서 둘 다 읽는다(실제 값은 --check에서 확인).
ROLE_LABELS = ("cnpg.io/instanceRole", "role")
PRIMARY = "primary"
REPLICA = "replica"

KUBECTL_TIMEOUT_S = 30
POLL_INTERVAL_S = 2.0
EXIT_USAGE = 2
EXIT_BLOCKED = 3
EXIT_PRECHECK_FAILED = 4

DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}")
DEFAULT_LLM_BASIS = Path(__file__).resolve().parent / "llm-call-basis.json"

# --- 삭제 조건 검증(--verify-delete) ---
# 운영 네임스페이스에서 이 검증을 돌리지 못하도록 테스트 네임스페이스 이름에 접두어를 강제한다.
TEST_NAMESPACE_PREFIX = "mafest-fault-test"
DUMMY_IMAGE = (
    "registry.k8s.io/pause:3.9"  # 스케줄되지 않는 Pod라 실제로 pull하지 않는다.
)
DUMMY_SCHEDULER = "mafest-fault-verify-no-scheduler"  # 존재하지 않는 스케줄러라 Pod가 Pending으로 남는다.
VERIFICATION_MAX_AGE = timedelta(hours=24)
VERIFICATION_KIND = "mafest-delete-precondition-verification"
DELETE_MODE_PRECONDITION = "uid+resourceVersion"
DUMMY_WAIT_S = 10.0

# --- vLLM 무효 판정 ---
VLLM_METRICS_URL = (
    "http://persona-vllm.persona-inference.svc.cluster.local:8000/metrics"
)
VLLM_COUNTER = "vllm:request_prompt_tokens_count"
# vLLM Pod 신원. 컨테이너/Pod 재시작은 카운터를 0으로 되돌리는데, 리셋 직후 값이 우연히 이전 값 이상이 되면
# "감소" 검사만으로는 놓친다. 그래서 Pod UID와 컨테이너 재시작 횟수를 따로 기록하고 바뀌면 관측 불연속으로 본다.
VLLM_NAMESPACE = "persona-inference"
VLLM_SELECTOR = "app.kubernetes.io/name=persona-vllm"
# 측정 Pod 안에서 vLLM /metrics를 읽어 카운터 합(라벨 무시)을 출력한다. 없으면 MISSING.
METRIC_READER_SCRIPT = r"""
import re, sys, urllib.request
text = urllib.request.urlopen(sys.argv[1], timeout=5).read().decode()
pattern = re.compile(r"^" + re.escape(sys.argv[2]) + r"(?:\{[^}]*\})?\s+([0-9.eE+-]+)\s*$", re.M)
values = [float(v) for v in pattern.findall(text)]
print(sum(values) if values else "MISSING")
"""

#: 실행 전 안내. vLLM 카운터는 공유 엔진 전체 값이라 다른 요청이 섞이면 오탐(무효·중단)이 난다.
OTHER_LLM_TRAFFIC_NOTICE = (
    "전제: 측정하는 동안 vLLM에는 이 실험 외의 LLM 요청이 없어야 한다(웹/다른 api/다른 클라이언트의 검색·"
    "스트림·설명 호출 포함). vLLM 카운터는 엔진 전체 값이라 다른 요청이 섞이면 증가가 감지되어 실험이 중단되거나 "
    "무효로 표시된다. 실행 전에 트래픽이 없는지 사람이 확인한다."
)

# 읽기 전용 관측에 쓰는 고정 SQL. 쿼리 원문·접속 정보는 기록하지 않고 집계만 남긴다.
SQL_XACT_COMMIT = (
    "SELECT xact_commit FROM pg_stat_database WHERE datname = current_database()"
)
SQL_ACTIVITY = (
    "SELECT usename, state, count(*) FROM pg_stat_activity "
    "WHERE datname = current_database() GROUP BY 1, 2 ORDER BY 1, 2"
)

# 측정 Pod 안에서 도는 표준 라이브러리 전용 반복 요청기. 설정은 argv의 JSON, 결과는 한 줄 CSV로 stdout에 낸다.
PROBE_SCRIPT = r"""
import datetime, json, sys, time, urllib.error, urllib.request
cfg = json.loads(sys.argv[1])
url = "http://127.0.0.1:8000" + cfg["path"]
data = json.dumps(cfg["body"]).encode() if cfg.get("body") is not None else None
headers = {"Content-Type": "application/json"} if data is not None else {}
start = time.monotonic()
for seq in range(cfg["count"]):
    sent = datetime.datetime.now(datetime.timezone.utc).isoformat()
    t0 = time.monotonic()
    code, err = 0, ""
    try:
        req = urllib.request.Request(url, data=data, method=cfg["method"], headers=headers)
        with urllib.request.urlopen(req, timeout=cfg["timeout_s"]) as response:
            code = response.status
            response.read()
    except urllib.error.HTTPError as error:
        code, err = error.code, "http_error"
    except Exception as error:
        err = type(error).__name__
    print(f"{sent},{seq},{code},{(time.monotonic() - t0) * 1000:.0f},{err}", flush=True)
    time.sleep(max(0.0, start + (seq + 1) * cfg["interval_s"] - time.monotonic()))
"""


def file_sha256(path: Path) -> str:
    """파일 내용의 sha256. 실측 기록이 어느 버전의 도구·근거표로 만들어졌는지 커밋과 대조하는 데 쓴다."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tool_fingerprint(llm_basis: Path) -> dict[str, str]:
    """실행 중인 도구 파일과 LLM 호출 근거표의 해시. Git 에 커밋된 같은 파일의 sha256 과 비교한다."""
    return {
        "mafest_fault_py_sha256": file_sha256(Path(__file__).resolve()),
        "llm_call_basis_json_sha256": file_sha256(llm_basis),
    }


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class PreflightFailed(Exception):
    """시작 조건이 맞지 않는다. 쓰기 명령을 보내기 전에만 발생한다."""

    def __init__(
        self, reasons: list[str], exit_code: int = EXIT_PRECHECK_FAILED
    ) -> None:
        super().__init__("; ".join(reasons))
        self.reasons = reasons
        self.exit_code = exit_code


class NotReady(PreflightFailed):
    """아직 실행할 준비가 안 됐다(검증·근거 부족). 종료 코드 3."""

    def __init__(self, reasons: list[str]) -> None:
        super().__init__(reasons, EXIT_BLOCKED)


@dataclass(frozen=True)
class Experiment:
    """ID별 고정 정의. 판정 기준은 실행 전에 정해 두고 바꾸지 않는다."""

    id: str
    title: str
    max_fault_requests: int
    fault: str
    criterion: str
    blocked_by: tuple[str, ...] = ()

    @property
    def ready(self) -> bool:
        return not self.blocked_by


EXPERIMENTS: dict[str, Experiment] = {
    e.id: e
    for e in (
        Experiment(
            "E0",
            "rw 단일 연결에서 DB Primary 장애 기준선",
            1,
            "Primary Pod 강제 삭제 요청 1회",
            "수치 기록만(실패 구간·전송/앱 오류·실제 역할 전환·회복 시간). 통과/실패를 정하지 않는다."
            " vLLM 카운터가 늘면 실험 무효로 표시한다.",
        ),
        Experiment(
            "E1",
            "첫 턴 뒤 담당 API Pod가 바뀌어도 확인 답변을 이어 받음",
            1,
            "API Pod 강제 삭제 요청 1회",
            "조건 보존·세션 접근·정상 결과. 반복 상한은 사전 확정.",
            ("운영 세션 API·공유 상태·소유권 계약 미확정",),
        ),
        Experiment(
            "E2",
            "같은 턴 키로 답변 5건 동시 제출(장애 없음)",
            0,
            "없음(동시성 시험)",
            "턴 접수·활성 소유자·응답 replay와 단계별 생성 시도. vLLM 합계 1을 요구하지 않음.",
            ("DB 고유 키·소유권·멱등성·시도 관측 계약 미확정",),
        ),
        Experiment(
            "E3",
            "생성 중 담당 API 프로세스 장애 후 같은 키 재접속",
            1,
            "API Pod 강제 삭제 요청 1회",
            "만료·회복/명시적 실패·중복 결과 commit·유령 소유자 여부.",
            ("lease·fencing·불명확한 외부 생성 처리 정책 미확정",),
        ),
        Experiment(
            "E4",
            "두 턴 사이 DB Primary 장애",
            1,
            "Primary Pod 강제 삭제 요청 1회",
            "승인된 상태 손실·복구·재요청 결과(비동기 복제에서 무조건 손실 0은 약속하지 않음).",
            ("세션 API·CNPG 복제/commit/RPO·상태 복구 계약 미확정",),
        ),
        Experiment(
            "E5",
            "멀티턴 중 API 롤링 교체",
            2,
            "API Pod 순차 교체(최대 2대)",
            "요청 실패·기준 보존·중복 commit·완료/회복 지연.",
            ("승인 이미지·drain·세션 API·계획·복구 경로 미확정",),
        ),
    )
}


class ForbiddenCall(Exception):
    """허용하지 않은 kubectl 호출을 실행하려 했다."""


@dataclass
class Kubectl:
    """모든 kubectl 호출이 지나는 유일한 관문.

    - `--context <승인값>`을 항상 앞에 붙여, 현재 context가 바뀌어도 다른 클러스터로 새지 않는다.
    - 허용한 동사와 `guard`(추가 규칙)를 통과한 호출만 실행한다.
    - 호출 인자를 기록한다(비밀값은 인자에 넣지 않는다).
    """

    context: str
    allowed_verbs: frozenset[str]
    guard: Callable[[list[str]], None] | None = None
    calls: list[list[str]] = field(default_factory=list)

    def argv(self, args: list[str]) -> list[str]:
        if not args or args[0] not in self.allowed_verbs:
            raise ForbiddenCall(args[0] if args else "")
        if self.guard is not None:
            self.guard(args)
        self.calls.append(["--context", self.context, *args])
        return [
            os.environ.get("MAFEST_KUBECTL", "kubectl"),
            "--context",
            self.context,
            *args,
        ]

    def run(
        self, args: list[str], stdin_text: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.argv(args),
            input=stdin_text,
            stdin=None if stdin_text is not None else subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=KUBECTL_TIMEOUT_S,
            check=False,
        )

    def popen(self, args: list[str]) -> subprocess.Popen[str]:
        """오래 도는 측정 프로세스용. 같은 관문을 지나므로 context·허용 동사 규칙이 똑같이 적용된다."""
        return subprocess.Popen(
            self.argv(args),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )

    def get_json(self, args: list[str]) -> dict:
        result = self.run(args)
        if result.returncode != 0:
            raise PreflightFailed([f"kubectl {args[0]} 실패(코드 {result.returncode})"])
        return json.loads(result.stdout)


def run_mode_guard(args: list[str]) -> None:
    """--run 에서는 delete 가 DB 네임스페이스 Pod 의 raw 삭제(UID 조건 본문)뿐이다. 이름 삭제는 허용하지 않는다."""
    if args[0] != "delete":
        return
    if args[1] != "--raw" or not args[2].startswith(
        f"/api/v1/namespaces/{DATA_NAMESPACE}/pods/"
    ):
        raise ForbiddenCall("delete 대상")


def verify_mode_guard(namespace: str) -> Callable[[list[str]], None]:
    """--verify-delete 에서는 테스트 네임스페이스 밖의 어떤 호출도 허용하지 않는다."""

    def guard(args: list[str]) -> None:
        if args[0] in ("config", "version"):
            return
        in_namespace = namespace in args or any(
            f"/namespaces/{namespace}/" in a for a in args
        )
        if not in_namespace and args[:2] != ["get", "namespace"]:
            raise ForbiddenCall("테스트 네임스페이스 밖 호출")
        if args[0] == "get" and args[1] == "namespace" and args[2] != namespace:
            raise ForbiddenCall("테스트 네임스페이스 밖 조회")

    return guard


@dataclass(frozen=True)
class PodInfo:
    name: str
    uid: str
    resource_version: str
    node: str
    ready: bool
    role: str
    image_digest: str
    env: dict[str, str] = field(default_factory=dict)
    # 값을 알 수 없는 설정: envFrom 이 있거나 valueFrom 으로 주입되는 이름. 'unset' 과 구분하려고 따로 둔다.
    has_env_from: bool = False
    value_from_names: frozenset[str] = frozenset()


def parse_pod(item: dict) -> PodInfo:
    labels = item["metadata"].get("labels", {})
    role = next((labels[key] for key in ROLE_LABELS if key in labels), "")
    status = item.get("status", {})
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in status.get("conditions", [])
    )
    digest = ""
    for container in status.get("containerStatuses", []):
        match = DIGEST_PATTERN.search(container.get("imageID", ""))
        if container.get("name") == API_CONTAINER and match:
            digest = match.group(0)
    env: dict[str, str] = {}
    value_from: set[str] = set()
    has_env_from = False
    for container in item["spec"].get("containers", []):
        if container.get("name") == API_CONTAINER:
            has_env_from = bool(container.get("envFrom"))
            for variable in container.get("env", []):
                if "valueFrom" in variable:
                    # Secret/ConfigMap 참조는 값을 읽지 않는다. 모르는 값이므로 따로 표시한다.
                    value_from.add(variable["name"])
                else:
                    env[variable["name"]] = variable.get("value", "")
    return PodInfo(
        item["metadata"]["name"],
        item["metadata"]["uid"],
        item["metadata"].get("resourceVersion", ""),
        item["spec"].get("nodeName", ""),
        ready,
        role,
        digest,
        env,
        has_env_from,
        frozenset(value_from),
    )


def parse_pods(document: dict) -> list[PodInfo]:
    return [parse_pod(item) for item in document.get("items", [])]


@dataclass
class Targets:
    context: str
    api_pods: list[PodInfo]
    db_pods: list[PodInfo]
    primary: PodInfo
    client: PodInfo


def version_fingerprint(kubectl: Kubectl) -> dict:
    """삭제 조건 동작은 kubectl·서버 버전에 달려 있어서 검증 기록과 같은 버전인지 비교한다."""
    result = kubectl.run(["version", "-o", "json"])
    if result.returncode != 0:
        raise PreflightFailed(["kubectl version 을 읽지 못했다"])
    document = json.loads(result.stdout)
    return {
        "client": document.get("clientVersion", {}).get("gitVersion", ""),
        "server": document.get("serverVersion", {}).get("gitVersion", ""),
    }


def preflight(kubectl: Kubectl, expected_context: str) -> Targets:
    """읽기 전용 사전 점검. 하나라도 어긋나면 모든 이유를 모아 PreflightFailed로 알린다."""
    contexts = kubectl.run(["config", "get-contexts", "-o", "name"]).stdout.split()
    if expected_context not in contexts:
        raise PreflightFailed([f"kubeconfig 에 context {expected_context!r} 가 없다"])

    reasons: list[str] = []
    api = parse_pods(
        kubectl.get_json(
            ["get", "pods", "-n", APP_NAMESPACE, "-l", API_SELECTOR, "-o", "json"]
        )
    )
    db = [
        p
        for p in parse_pods(
            kubectl.get_json(
                ["get", "pods", "-n", DATA_NAMESPACE, "-l", DB_SELECTOR, "-o", "json"]
            )
        )
        if p.role
    ]
    if len([p for p in api if p.ready]) != 2:
        reasons.append("Ready인 api Pod가 2개가 아니다")
    if len({p.node for p in api if p.ready}) != 2:
        reasons.append("api Pod 2개가 서로 다른 노드에 있지 않다")
    if len([p for p in db if p.ready]) != 2:
        reasons.append("Ready인 CNPG 인스턴스가 2개가 아니다")
    primaries = [p for p in db if p.role == PRIMARY]
    if len(primaries) != 1 or len([p for p in db if p.role == REPLICA]) != 1:
        reasons.append("Primary 1개·Replica 1개 구성이 아니다")
    if reasons:
        raise PreflightFailed(reasons)

    primary = primaries[0]
    # 측정기는 장애 대상과 다른 노드에서 돌려야 같이 죽지 않는다.
    clients = [p for p in api if p.ready and p.node != primary.node]
    if not clients:
        raise PreflightFailed(["Primary와 다른 노드의 Ready api Pod(측정용)가 없다"])
    return Targets(expected_context, api, db, primary, clients[0])


# --- 요청 경로별 LLM 호출 상한: 코드로 증명한 것만 ---
#
# 관측값(과거 몇 건에서 호출이 없었다)은 근거로 쓰지 않는다. 요청당 LLM 호출 수는 이미지, 생성 설정, 질문에
# 따라 달라지므로, 경로마다 "그 이미지의 코드에서 LLM 호출 지점에 도달할 수 있는가"를 코드로 추적한 증명만
# 상한으로 인정한다. 증명에는 이미지 digest, 검토한 커밋, 진입점·호출 경로·분기 조건·설정 기본값을 함께 적는다.
# 실행 중인 api digest가 증명의 digest와 다르면 증명은 무효이고 경로는 다시 "준비 안 됨"이 된다.
# 도달 가능한 경로(예: /v1/search)는 상한을 정할 수 없으므로 llm_call_upper_bound 가 null 이고 거부된다.
#
# 이 도구가 아는 한계: 이미지 digest ↔ 커밋의 대응은 배포 매니페스트 주석에 적힌 값이며 빌드 출처는
# 검증하지 못했다(provenance_verified 가 false). --check 와 --run 이 이 사실을 출력한다.

#: 값이 알려지지 않으면 확인 불가로 막는 설정 이름. 호출 수를 바꿀 수 있는 생성 설정과 재시도 횟수다.
MONITORED_SETTING_NAMES = (
    "MAFEST_LLM_SUMMARY",
    "MAFEST_LLM_SUGGEST",
    "MAFEST_LLM_RETRIES",
    "LLM_USE_MOCK",
    "MAFEST_LLM_MODEL",
    "MAFEST_LLM_BASE_URL",
)


@dataclass(frozen=True)
class RouteProof:
    """한 경로에 대해 코드로 증명한 LLM 호출 상한과 그 근거."""

    pattern: str
    method: str
    request_kind: str
    llm_call_upper_bound: int
    api_image_digest: str
    reviewed_commit: str
    provenance_verified: bool
    entrypoint: str
    call_chain: tuple[str, ...]
    branches: tuple[str, ...]
    settings_dependency: str


def parse_route_proof(pattern: str, entry: dict) -> RouteProof | None:
    """증명이 완전하고 상한이 정수일 때만 RouteProof 를 돌려준다. 하나라도 비면 None(거부)이다."""
    proof = entry.get("proof") or {}
    bound = entry.get("llm_call_upper_bound")
    parts = (
        entry.get("method"),
        entry.get("request_kind"),
        proof.get("entrypoint"),
        proof.get("call_chain"),
        proof.get("branches"),
        proof.get("settings_dependency"),
        proof.get("reviewed_commit"),
    )
    if (
        not isinstance(bound, int)
        or isinstance(bound, bool)
        or bound < 0
        or not all(parts)
        or not DIGEST_PATTERN.fullmatch(proof.get("api_image_digest") or "")
    ):
        return None
    return RouteProof(
        pattern,
        entry["method"],
        entry["request_kind"],
        bound,
        proof["api_image_digest"],
        proof["reviewed_commit"],
        bool(proof.get("provenance_verified")),
        proof["entrypoint"],
        tuple(proof["call_chain"]),
        tuple(proof["branches"]),
        proof["settings_dependency"],
    )


def load_llm_basis(path: Path) -> dict[str, RouteProof]:
    """llm-call-basis.json 을 읽는다. 증명이 불완전하거나 상한이 null 인 경로는 표에서 빠진다."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise NotReady(
            [f"LLM 호출 근거 파일을 읽지 못했다({type(error).__name__})"]
        ) from None
    routes: dict[str, RouteProof] = {}
    for pattern, entry in raw.get("routes", {}).items():
        proof = parse_route_proof(pattern, entry)
        if proof is not None:
            routes[pattern] = proof
    return routes


def match_route(path: str, routes: dict[str, RouteProof]) -> RouteProof | None:
    """요청 경로를 표의 패턴(`{domain}` 같은 자리 포함)과 맞춰 본다. `?`·`#` 가 있는 경로는 거부한다."""
    if "?" in path or "#" in path:
        return None
    for pattern, proof in routes.items():
        regex = "^" + re.sub(r"\\\{[a-z_]+\\\}", "[^/]+", re.escape(pattern)) + "$"
        if re.fullmatch(regex, path):
            return proof
    return None


@dataclass(frozen=True)
class E0Inputs:
    """E0 사전 입력. 비어 있으면 실행하지 않는다."""

    method: str
    request_kind: str
    path: str
    body: dict | None
    interval_s: float
    duration_s: float
    inject_after_s: float
    request_timeout_s: float
    gpu_call_cap: int
    abort_after_consecutive_failures: int
    recovery_timeout_s: float
    llm_counter_poll_s: float = 10.0

    @property
    def planned_requests(self) -> int:
        return int(self.duration_s / self.interval_s)


def load_e0_inputs(
    path: Path, routes: dict[str, RouteProof]
) -> tuple[E0Inputs, RouteProof]:
    """입력을 읽고, 경로·방식·요청 종류·LLM 호출 예산을 증명 표와 대조한다."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PreflightFailed(
            [f"입력 파일을 읽지 못했다({type(error).__name__})"]
        ) from None
    required = (
        "method",
        "request_kind",
        "path",
        "interval_s",
        "duration_s",
        "inject_after_s",
        "request_timeout_s",
        "gpu_call_cap",
        "abort_after_consecutive_failures",
        "recovery_timeout_s",
    )
    missing = [f"입력 {key} 가 비어 있다" for key in required if raw.get(key) is None]
    if missing:
        raise PreflightFailed(missing)
    values = {key: raw[key] for key in required}
    values["body"] = raw.get("body")
    if raw.get("llm_counter_poll_s") is not None:
        values["llm_counter_poll_s"] = raw["llm_counter_poll_s"]
    inputs = E0Inputs(**values)

    problems: list[str] = []
    proof = match_route(inputs.path, routes)
    if proof is None:
        # 증명되지 않은 경로(LLM 도달 가능 경로 포함)는 호출 상한을 정할 수 없어 거부한다.
        problems.append(
            f"경로 {inputs.path} 는 LLM 호출 상한이 코드로 증명되지 않아 거부한다"
            "(도달 가능한 경로이거나 증명 항목이 비어 있다)"
        )
    else:
        if inputs.method != proof.method:
            problems.append(f"경로 {proof.pattern} 의 방식은 {proof.method} 여야 한다")
        if inputs.request_kind != proof.request_kind:
            problems.append(
                f"경로 {proof.pattern} 의 요청 종류는 {proof.request_kind} 여야 한다"
            )
    if inputs.interval_s <= 0 or inputs.inject_after_s >= inputs.duration_s:
        problems.append("interval_s > 0 이고 inject_after_s < duration_s 여야 한다")
    if inputs.request_timeout_s > 90:
        problems.append("request_timeout_s 가 앱 요청 상한 90초를 넘는다")
    if inputs.llm_counter_poll_s <= 0:
        problems.append("llm_counter_poll_s 는 0보다 커야 한다")
    if proof is not None:
        budget = inputs.planned_requests * proof.llm_call_upper_bound
        if budget > inputs.gpu_call_cap:
            problems.append(
                f"LLM 호출 예산({inputs.planned_requests}건 × 증명된 상한 "
                f"{proof.llm_call_upper_bound}회 = {budget})이 상한({inputs.gpu_call_cap})을 넘는다"
            )
        elif inputs.gpu_call_cap > budget:
            # cap 은 증명된 예산과 같아야 한다. 더 크게 적으면 감시 기준이 느슨해지므로 오입력으로 보고 거부한다.
            # (증명된 상한이 0 인 상품 상세는 0 만 허용된다.)
            problems.append(
                f"gpu_call_cap({inputs.gpu_call_cap})이 증명된 예산({budget} = "
                f"{inputs.planned_requests}건 × {proof.llm_call_upper_bound}회)보다 크다. 오입력으로 보고 거부한다"
            )
    abort_window_s = inputs.abort_after_consecutive_failures * inputs.interval_s
    if abort_window_s < inputs.recovery_timeout_s:
        # 측정하려는 것이 끊김 시간이다. 복구를 기다리기로 한 시간보다 먼저 측정을 접으면 회복 시간을 못 잰다.
        problems.append(
            f"중단 기준({inputs.abort_after_consecutive_failures}회 × {inputs.interval_s}초 = {abort_window_s:g}초)이"
            f" recovery_timeout_s({inputs.recovery_timeout_s:g}초)보다 짧다. 연속 실패 중단 기준은"
            " 복구 대기 시한 이상이어야 한다"
        )
    if problems:
        raise PreflightFailed(problems)
    assert proof is not None
    return inputs, proof


def input_warnings(inputs: E0Inputs) -> list[str]:
    """거부할 정도는 아니지만 사람이 알아야 하는 입력 조합."""
    warnings: list[str] = []
    after_injection_s = inputs.duration_s - inputs.inject_after_s
    abort_window_s = inputs.abort_after_consecutive_failures * inputs.interval_s
    if abort_window_s > after_injection_s:
        warnings.append(
            f"연속 실패 중단 기준({abort_window_s:g}초)이 주입 뒤 남은 측정 시간({after_injection_s:g}초)보다 길어"
            " 이 기준으로는 측정이 중단되지 않는다(중단 기준이 비활성이다)"
        )
    if inputs.recovery_timeout_s > after_injection_s:
        warnings.append(
            f"복구 대기 시한({inputs.recovery_timeout_s:g}초)이 주입 뒤 측정 시간({after_injection_s:g}초)보다 길다."
            " 회복은 측정이 끝난 뒤 역할 관측으로 이어서 기다린다"
        )
    return warnings


def check_proof_context(proof: RouteProof, api_pods: list[PodInfo]) -> None:
    """증명이 지금 실행 중인 이미지에 유효한지 본다: digest 일치, 그리고 설정을 확인할 수 있어야 한다."""
    reasons: list[str] = []
    running = {p.image_digest for p in api_pods}
    if running != {proof.api_image_digest}:
        reasons.append(
            "실행 중인 api 이미지 digest가 증명의 digest와 다르거나 읽히지 않는다"
        )
    for pod in api_pods:
        if pod.has_env_from:
            reasons.append(
                f"{pod.name} 는 envFrom 으로 설정을 주입해 값을 확인할 수 없다"
            )
        for name in MONITORED_SETTING_NAMES:
            if name in pod.value_from_names:
                reasons.append(
                    f"{pod.name} 의 {name} 는 valueFrom 이라 값을 확인할 수 없다"
                )
    if reasons:
        raise NotReady(["LLM 호출 상한 증명을 적용할 수 없다: " + "; ".join(reasons)])


# --- 삭제 조건 검증 기록 ---


def delete_options_body(uid: str, resource_version: str) -> str:
    return json.dumps(
        {
            "apiVersion": "v1",
            "kind": "DeleteOptions",
            "gracePeriodSeconds": 0,
            "preconditions": {"uid": uid, "resourceVersion": resource_version},
        }
    )


def classify_delete(result: subprocess.CompletedProcess[str]) -> str:
    """삭제 응답을 분류한다. 서버 오류 원문은 남기지 않고 분류만 기록한다."""
    if result.returncode == 0:
        return "accepted"
    error = result.stderr
    if "Conflict" in error or "409" in error:
        return "conflict"
    if "NotFound" in error or "not found" in error:
        return "not_found"
    return "failed"


def raw_delete_pod(
    kubectl: Kubectl,
    namespace: str,
    name: str,
    uid: str,
    resource_version: str,
    work_dir: Path,
) -> str:
    """DeleteOptions 본문(preconditions)을 실어 Pod 하나를 삭제 요청하고 분류를 돌려준다."""
    body_path = work_dir / f"delete-options-{uuid.uuid4().hex[:8]}.json"
    body_path.write_text(delete_options_body(uid, resource_version), encoding="utf-8")
    try:
        result = kubectl.run(
            [
                "delete",
                "--raw",
                f"/api/v1/namespaces/{namespace}/pods/{name}",
                "-f",
                str(body_path),
            ]
        )
    finally:
        body_path.unlink(missing_ok=True)
    return classify_delete(result)


def pod_exists(kubectl: Kubectl, namespace: str, name: str) -> bool:
    result = kubectl.run(
        ["get", "pod", name, "-n", namespace, "--ignore-not-found", "-o", "name"]
    )
    return result.returncode == 0 and bool(result.stdout.strip())


def verify_delete_conditions(kubectl: Kubectl, namespace: str, out_path: Path) -> dict:
    """테스트 네임스페이스의 더미 Pod로 삭제 조건 세 경우를 검증하고 기록 dict를 돌려준다."""
    if kubectl.run(["get", "namespace", namespace, "-o", "name"]).returncode != 0:
        raise PreflightFailed(
            [f"테스트 네임스페이스 {namespace} 를 찾지 못했다(이 도구는 만들지 않는다)"]
        )
    fingerprint = version_fingerprint(kubectl)
    created: list[str] = []
    cases: dict[str, dict] = {}

    def make_dummy(label: str) -> PodInfo:
        name = f"fault-verify-{label}-{uuid.uuid4().hex[:6]}"
        manifest = {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"name": name, "labels": {"app": "mafest-fault-verify"}},
            "spec": {
                "schedulerName": DUMMY_SCHEDULER,
                "automountServiceAccountToken": False,
                "terminationGracePeriodSeconds": 0,
                "containers": [{"name": "dummy", "image": DUMMY_IMAGE}],
            },
        }
        created.append(name)
        if (
            kubectl.run(
                ["create", "-n", namespace, "-f", "-"], json.dumps(manifest)
            ).returncode
            != 0
        ):
            raise PreflightFailed(["더미 Pod 생성 실패"])
        return parse_pod(
            kubectl.get_json(["get", "pod", name, "-n", namespace, "-o", "json"])
        )

    try:
        with tempfile.TemporaryDirectory() as work:
            work_dir = Path(work)
            # 1) 틀린 UID: 409여야 하고 Pod는 남아 있어야 한다.
            dummy = make_dummy("uid")
            observed = raw_delete_pod(
                kubectl,
                namespace,
                dummy.name,
                "00000000-0000-0000-0000-000000000000",
                dummy.resource_version,
                work_dir,
            )
            remained = pod_exists(kubectl, namespace, dummy.name)
            cases["wrong_uid"] = {
                "expected": "conflict",
                "observed": observed,
                "pod_remained": remained,
            }
            # 2) 틀린 resourceVersion: 409여야 하고 Pod는 남아 있어야 한다.
            dummy = make_dummy("rv")
            wrong_rv = (
                str(int(dummy.resource_version) + 1)
                if dummy.resource_version.isdigit()
                else "0"
            )
            observed = raw_delete_pod(
                kubectl, namespace, dummy.name, dummy.uid, wrong_rv, work_dir
            )
            remained = pod_exists(kubectl, namespace, dummy.name)
            cases["wrong_resource_version"] = {
                "expected": "conflict",
                "observed": observed,
                "pod_remained": remained,
            }
            # 3) 정상 조건: 수락되고 Pod가 사라져야 한다.
            dummy = make_dummy("ok")
            observed = raw_delete_pod(
                kubectl,
                namespace,
                dummy.name,
                dummy.uid,
                dummy.resource_version,
                work_dir,
            )
            deadline = time.monotonic() + DUMMY_WAIT_S
            gone = not pod_exists(kubectl, namespace, dummy.name)
            while not gone and time.monotonic() < deadline:
                time.sleep(0.5)
                gone = not pod_exists(kubectl, namespace, dummy.name)
            cases["correct"] = {
                "expected": "accepted",
                "observed": observed,
                "pod_gone": gone,
            }
    finally:
        # 검증이 도중에 실패해도 만든 더미 Pod는 지운다(우리가 만든 이름만).
        for name in created:
            kubectl.run(
                [
                    "delete",
                    "pod",
                    name,
                    "-n",
                    namespace,
                    "--ignore-not-found",
                    "--wait=false",
                ]
            )

    passed = (
        cases["wrong_uid"]["observed"] == "conflict"
        and cases["wrong_uid"]["pod_remained"]
        and cases["wrong_resource_version"]["observed"] == "conflict"
        and cases["wrong_resource_version"]["pod_remained"]
        and cases["correct"]["observed"] == "accepted"
        and cases["correct"]["pod_gone"]
    )
    record = {
        "kind": VERIFICATION_KIND,
        "context": kubectl.context,
        "test_namespace": namespace,
        "verified_utc": utc_now(),
        "versions": fingerprint,
        "cases": cases,
        "passed": passed,
    }
    out_path.write_text(
        json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return record


def load_delete_verification(path: Path | None, context: str) -> dict:
    """삭제 조건 검증 기록을 읽는다. 없거나·낡았거나·다른 context 거나·실패면 준비 안 됨(중단)이다.

    검증이 실패했을 때 이름 삭제로 우회하는 길은 두지 않는다. 그 방식은 UID·resourceVersion 보호를 없앤다.
    """
    if path is None or not path.exists():
        raise NotReady(
            ["삭제 조건 검증 기록이 없다(--verify-delete 를 먼저 통과해야 한다)"]
        )
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
        verified = datetime.fromisoformat(record["verified_utc"])
    except (OSError, ValueError, KeyError):
        raise NotReady(["삭제 조건 검증 기록을 해석하지 못했다"]) from None
    if record.get("kind") != VERIFICATION_KIND or record.get("context") != context:
        raise NotReady(["삭제 조건 검증 기록이 이 context 의 것이 아니다"])
    if datetime.now(timezone.utc) - verified > VERIFICATION_MAX_AGE:
        raise NotReady(["삭제 조건 검증 기록이 24시간을 넘었다(다시 검증한다)"])
    if record.get("passed") is not True:
        raise NotReady(
            [
                "삭제 조건 검증이 통과하지 않았다. 원인을 해결하고 다시 검증한다(우회 경로 없음)"
            ]
        )
    return record


def check_record_versions(record: dict, current: dict) -> None:
    if record.get("versions") != current:
        raise NotReady(["kubectl·서버 버전이 검증 기록과 다르다(다시 검증한다)"])


# --- 관측 ---


class VllmIdentityError(Exception):
    """vLLM Pod를 하나로 특정하지 못했다(없음·둘 이상·Ready 아님). 교체 또는 재시작 중일 수 있다."""


@dataclass(frozen=True)
class VllmIdentity:
    """카운터가 같은 프로세스의 값인지 판별하는 신원. UID는 Pod 교체, 재시작 횟수는 컨테이너 재시작을 잡는다."""

    name: str
    uid: str
    restart_count: int
    ready: bool


def read_vllm_identity(kubectl: Kubectl) -> VllmIdentity:
    """persona-inference 의 vLLM Pod를 읽는다. 정확히 한 개가 아니면 VllmIdentityError 다."""
    document = kubectl.get_json(
        ["get", "pods", "-n", VLLM_NAMESPACE, "-l", VLLM_SELECTOR, "-o", "json"]
    )
    items = document.get("items", [])
    if len(items) != 1:
        raise VllmIdentityError(f"vLLM Pod 가 {len(items)}개다(정확히 1개여야 한다)")
    item = items[0]
    status = item.get("status", {})
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in status.get("conditions", [])
    )
    restarts = sum(
        int(c.get("restartCount", 0)) for c in status.get("containerStatuses", [])
    )
    return VllmIdentity(
        item["metadata"]["name"], item["metadata"]["uid"], restarts, ready
    )


def same_vllm_process(a: VllmIdentity, b: VllmIdentity) -> bool:
    return (a.uid, a.restart_count) == (b.uid, b.restart_count)


def check_measurement_python(kubectl: Kubectl, client: PodInfo) -> str:
    """측정 Pod(mafest-api 컨테이너)에 python3 가 있는지 시작 전에 확인하고 버전 문자열을 돌려준다.

    측정 요청기와 vLLM 카운터 읽기가 모두 이 컨테이너의 python3 표준 라이브러리에 기대므로,
    없으면 장애를 넣기 전에 끝낸다. 별도 디버그 이미지(netshoot 등)는 쓰지 않는다.
    """
    result = kubectl.run(
        ["exec", "-n", APP_NAMESPACE, client.name, "-c", API_CONTAINER, "--", "python3", "--version"]
    )  # fmt: skip
    # 버전 문자열은 stdout 또는 stderr 로 나올 수 있어 둘 다 본다.
    text = (result.stdout + result.stderr).strip()
    if result.returncode != 0 or not text.startswith("Python 3"):
        raise NotReady(
            [
                f"측정 컨테이너({client.name}/{API_CONTAINER})에서 python3 를 확인하지 못했다"
            ]
        )
    return text


class CounterReadError(Exception):
    """카운터 값을 신뢰할 수 있게 읽지 못했다(명령 실패, 숫자 아님, 비유한 값, 음수, 지표 없음)."""


def read_vllm_counter(kubectl: Kubectl, client: PodInfo) -> float:
    """측정 Pod 안에서 vLLM 카운터 합을 읽는다. 종료 코드가 0이 아니거나 값이 유한한 0 이상 실수가 아니면 거부한다."""
    result = kubectl.run(
        ["exec", "-n", APP_NAMESPACE, client.name, "-c", API_CONTAINER, "--",
         "python3", "-c", METRIC_READER_SCRIPT, VLLM_METRICS_URL, VLLM_COUNTER]
    )  # fmt: skip
    if result.returncode != 0:
        # 명령이 실패했으면 stdout 이 숫자처럼 보여도 믿지 않는다.
        raise CounterReadError(f"읽기 명령 실패(코드 {result.returncode})")
    text = result.stdout.strip()
    try:
        value = float(text)
    except ValueError:
        raise CounterReadError(f"숫자가 아닌 출력({text[:20] or '빈 출력'})") from None
    if not math.isfinite(value) or value < 0:
        raise CounterReadError("유한한 0 이상의 값이 아니다")
    return value


def read_db_observation(kubectl: Kubectl, pod: PodInfo) -> dict:
    """DB Pod에서 집계 두 가지를 읽는다(쿼리 원문·접속 정보 없음). 실패하면 '미확인'으로 남긴다."""
    observation: dict = {"pod": pod.name, "observed_utc": utc_now()}
    for key, sql in (("xact_commit", SQL_XACT_COMMIT), ("activity", SQL_ACTIVITY)):
        result = kubectl.run(
            [
                "exec",
                "-n",
                DATA_NAMESPACE,
                pod.name,
                "-c",
                "postgres",
                "--",
                "psql",
                "-d",
                DB_NAME,
                "-At",
                "-c",
                sql,
            ]
        )
        observation[key] = result.stdout.strip() if result.returncode == 0 else "미확인"
    return observation


def summarize_requests(rows: list[dict]) -> dict:
    """실패 건수·연속 실패 구간·최대 응답을 계산한다. 2xx가 아니면 실패다."""
    failures = [r for r in rows if not 200 <= int(r["http"]) < 300]
    intervals: list[dict] = []
    run: list[dict] = []
    for row in [*rows, {"http": "200", "utc": "", "seq": -1}]:
        if not 200 <= int(row["http"]) < 300:
            run.append(row)
        elif run:
            intervals.append(
                {
                    "start_utc": run[0]["utc"],
                    "end_utc": run[-1]["utc"],
                    "count": len(run),
                }
            )
            run = []
    latencies = [int(r["latency_ms"]) for r in rows]
    return {
        "total": len(rows),
        "failures": len(failures),
        "failure_intervals": intervals,
        "max_latency_ms": max(latencies) if latencies else None,
    }


@dataclass
class RunState:
    """실행 중 여러 스레드가 함께 쓰는 기록.

    장애 요청은 inject_once 로만, 그것도 lock 안에서만 보낸다. 중단 경로(finally)도 같은 lock 으로
    cancel_injection 을 세우므로 "중단이 먼저면 주입 없음, 주입이 먼저면 이미 끝난 뒤"가 보장된다.
    """

    lock: threading.Lock = field(default_factory=threading.Lock)
    cancel_injection: threading.Event = field(default_factory=threading.Event)
    fault_requests: int = 0
    fault_result: str = "미실행"
    fault_requested_utc: str = ""
    fault_responded_utc: str = ""
    roles: list[dict] = field(default_factory=list)
    stop: threading.Event = field(default_factory=threading.Event)
    problems: list[str] = field(default_factory=list)
    # vLLM 카운터 감시(측정 중 주기 확인)
    probe: subprocess.Popen[str] | None = None
    llm_exceeded: bool = False
    counter_discontinuity: bool = False
    counter_unknown_reads: int = 0
    counter_last: float | None = None
    vllm_replaced: bool = False


class TargetChanged(Exception):
    """승인한 대상과 지금 대상이 다르다."""


def recheck_target(kubectl: Kubectl, approved: PodInfo) -> PodInfo:
    """주입 직전에 대상을 다시 읽어 승인값과 같은지 확인하고, 최신 resourceVersion 을 담아 돌려준다."""
    result = kubectl.run(
        ["get", "pod", approved.name, "-n", DATA_NAMESPACE, "-o", "json"]
    )
    if result.returncode != 0:
        raise TargetChanged("대상 Pod 를 다시 읽지 못했다(삭제·재생성 가능성)")
    current = parse_pod(json.loads(result.stdout))
    if current.uid != approved.uid:
        raise TargetChanged("같은 이름의 Pod UID 가 승인값과 다르다(재생성)")
    if current.node != approved.node:
        raise TargetChanged("대상 Pod 의 노드가 승인값과 다르다")
    if current.role != PRIMARY or not current.ready:
        raise TargetChanged("대상 Pod 가 더 이상 Ready 인 Primary 가 아니다")
    return current


def inject_once(
    kubectl: Kubectl, state: RunState, approved: PodInfo, work_dir: Path
) -> None:
    """승인된 Primary Pod에 강제 삭제 요청을 정확히 한 번 보낸다. 실패·유실·409여도 다시 보내지 않는다."""
    try:
        try:
            current = recheck_target(kubectl, approved)
        except TargetChanged as changed:
            state.fault_result = f"주입 취소: {changed}"
            return
        with state.lock:
            # 락 안에서 중단 여부를 보고 요청까지 보낸다. 여기서 보지 않으면 중단 직후에도 주입될 수 있다.
            if state.cancel_injection.is_set():
                state.fault_result = "주입 취소(측정 중단 상태)"
                return
            if state.fault_requests >= EXPERIMENTS["E0"].max_fault_requests:
                return
            state.fault_requests += 1
            state.fault_requested_utc = utc_now()
            try:
                outcome = raw_delete_pod(
                    kubectl,
                    DATA_NAMESPACE,
                    current.name,
                    current.uid,
                    current.resource_version,
                    work_dir,
                )
                state.fault_result = {
                    "accepted": "요청 수락",
                    "conflict": "조건 불일치(409): 주입 취소, 재시도 없음",
                    "not_found": "대상 없음(404): 주입 취소, 재시도 없음",
                }.get(outcome, "거절·실패")
            except (subprocess.TimeoutExpired, OSError):
                # 응답이 유실됐으면 Pod가 지워졌는지 알 수 없다. 재전송하지 않고 미확인으로 남긴다.
                state.fault_result = "미확인(응답 유실)"
            state.fault_responded_utc = utc_now()
    except Exception as error:  # noqa: BLE001 - 타이머 스레드의 예외가 조용히 사라지지 않게 기록한다.
        state.problems.append(f"주입 스레드 오류: {type(error).__name__}")


MAX_CONSECUTIVE_UNKNOWN_READS = 3


def watch_vllm_counter(
    kubectl: Kubectl,
    state: RunState,
    client: PodInfo,
    baseline: float,
    baseline_identity: VllmIdentity,
    cap: int,
    poll_s: float,
) -> None:
    """측정 중 주기적으로 vLLM 카운터와 vLLM Pod 신원을 함께 확인한다.

    - Pod UID·컨테이너 재시작 횟수가 시작 때와 다르거나 Pod가 하나로 특정되지 않으면, 카운터 값과 무관하게
      관측 불연속으로 보고 중단한다(리셋 직후 값이 우연히 이전 값 이상이면 감소 검사가 놓치기 때문이다).
      신원은 카운터 읽기 앞뒤로 두 번 확인해 읽는 도중의 교체도 잡는다.
    - 증가량이 상한을 넘으면 장애 주입을 취소하고 측정 프로세스를 멈춘다(피해 한도이지 호출 예방이 아니다).
    - 값이 감소하면 재시작·리셋으로 보고 같은 방식으로 중단한다.
    - 읽기에 연속 실패하면 미확인 구간으로 기록하고, 3회 연속이면 같은 방식으로 중단한다.
    """
    previous = baseline
    consecutive_unknown = 0
    while not state.stop.wait(poll_s):
        try:
            first = read_vllm_identity(kubectl)
            value = read_vllm_counter(kubectl, client)
            second = read_vllm_identity(kubectl)
        except VllmIdentityError as error:
            # Pod 가 사라졌거나 둘이 되었으면 교체·재시작 중이다. 읽기 실패와 달리 바로 불연속으로 본다.
            state.vllm_replaced = True
            state.problems.append(f"vLLM Pod 교체/재시작 의심으로 중단: {error}")
            halt_measurement(state)
            return
        except (
            CounterReadError,
            PreflightFailed,
            subprocess.TimeoutExpired,
            OSError,
            ValueError,
        ):
            consecutive_unknown += 1
            state.counter_unknown_reads += 1
            if consecutive_unknown >= MAX_CONSECUTIVE_UNKNOWN_READS:
                state.problems.append("vLLM 카운터/Pod 연속 읽기 실패로 중단")
                halt_measurement(state)
                return
            continue
        consecutive_unknown = 0
        if not (
            same_vllm_process(first, baseline_identity)
            and same_vllm_process(second, baseline_identity)
        ):
            state.vllm_replaced = True
            state.problems.append(
                "vLLM Pod UID 또는 재시작 횟수 변경(관측 불연속)으로 중단"
            )
            halt_measurement(state)
            return
        state.counter_last = value
        if value < previous:
            state.counter_discontinuity = True
            state.problems.append("vLLM 카운터 감소(관측 불연속)로 중단")
            halt_measurement(state)
            return
        previous = value
        if value - baseline > cap:
            state.llm_exceeded = True
            state.problems.append("vLLM 카운터 증가량이 상한을 넘어 중단")
            halt_measurement(state)
            return


def halt_measurement(state: RunState) -> None:
    """측정을 멈추고 아직 보내지 않은 장애 주입을 취소한다. 주입과 같은 락을 쓰므로 순서가 보장된다."""
    with state.lock:
        state.cancel_injection.set()
    probe = state.probe
    if probe is not None and probe.poll() is None:
        probe.terminate()


def observe_roles(kubectl: Kubectl, state: RunState) -> None:
    """2초마다 CNPG Pod의 역할·Ready를 읽어 같은 시계(UTC)로 기록한다."""
    while not state.stop.is_set():
        try:
            pods = parse_pods(
                kubectl.get_json(
                    [
                        "get",
                        "pods",
                        "-n",
                        DATA_NAMESPACE,
                        "-l",
                        DB_SELECTOR,
                        "-o",
                        "json",
                    ]
                )
            )
            state.roles.append(
                {
                    "utc": utc_now(),
                    "pods": [
                        {"name": p.name, "role": p.role, "ready": p.ready}
                        for p in pods
                        if p.role
                    ],
                }
            )
        except (PreflightFailed, subprocess.TimeoutExpired, json.JSONDecodeError):
            state.roles.append({"utc": utc_now(), "pods": "관측 실패"})
        state.stop.wait(POLL_INTERVAL_S)


def recovery_seconds(state: RunState) -> float | None:
    """장애 요청 이후 Ready 2개·Primary 1개가 처음 다시 관측된 시점까지의 초. 관측 해상도는 2초 안팎이다."""
    if not state.fault_responded_utc:
        return None
    start = datetime.fromisoformat(state.fault_responded_utc)
    for sample in state.roles:
        pods = sample["pods"]
        if isinstance(pods, list) and datetime.fromisoformat(sample["utc"]) > start:
            ready = [p for p in pods if p["ready"]]
            primaries = [p for p in pods if p["role"] == PRIMARY]
            if len(ready) == 2 and len(primaries) == 1:
                return (datetime.fromisoformat(sample["utc"]) - start).total_seconds()
    return None


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def run_e0(
    kubectl: Kubectl,
    targets: Targets,
    inputs: E0Inputs,
    proof: RouteProof,
    out_dir: Path,
    llm_basis: Path = DEFAULT_LLM_BASIS,
) -> dict:
    out_dir.mkdir(parents=True, exist_ok=False)
    state = RunState()
    plan = {
        "experiment": "E0",
        "started_utc": utc_now(),
        "context": targets.context,
        "target": {
            "namespace": DATA_NAMESPACE,
            "name": targets.primary.name,
            "uid": targets.primary.uid,
            "node": targets.primary.node,
            "role": targets.primary.role,
        },
        "client": {
            "namespace": APP_NAMESPACE,
            "name": targets.client.name,
            "uid": targets.client.uid,
            "node": targets.client.node,
        },
        "inputs": dict(inputs.__dict__),
        "llm_call_proof": {
            "note": "코드로 증명한 상한이다(관측값 아님). 이미지 digest가 같을 때만 유효하다.",
            "route": proof.pattern,
            "llm_call_upper_bound": proof.llm_call_upper_bound,
            "api_image_digest": proof.api_image_digest,
            "reviewed_commit": proof.reviewed_commit,
            "provenance_verified": proof.provenance_verified,
            "entrypoint": proof.entrypoint,
            "call_chain": list(proof.call_chain),
            "branches": list(proof.branches),
            "settings_dependency": proof.settings_dependency,
        },
        "premise": OTHER_LLM_TRAFFIC_NOTICE,
        "tool": tool_fingerprint(llm_basis),
        "measurement_container": f"{APP_NAMESPACE}/{targets.client.name}/{API_CONTAINER}",
        "delete_mode": DELETE_MODE_PRECONDITION,
        "fault": "Primary Pod 강제 삭제 요청(grace-period=0). 프로세스 종료·fencing 보장 아님",
    }
    write_json(out_dir / "plan.json", plan)

    rows: list[dict] = []
    aborted = False
    abort_reason = ""
    timer: threading.Timer | None = None
    probe: subprocess.Popen[str] | None = None
    observer: threading.Thread | None = None
    watcher: threading.Thread | None = None
    before: dict = {}
    after: dict = {}
    vllm_before: float | None = None
    vllm_identity_before: VllmIdentity | None = None
    vllm_identity_after: VllmIdentity | str = "미확인"
    python_version = "미확인"
    vllm_after: float | str | None = None
    client_epoch: float | None = None
    local_mid = 0.0
    try:
        # 기준 읽기가 하나라도 실패하면 장애를 넣기 전에 끝낸다(무효 판정을 못 하는 실험은 시작하지 않는다).
        python_version = check_measurement_python(kubectl, targets.client)
        # 카운터를 믿으려면 같은 vLLM 프로세스여야 한다. 시작 시점의 신원을 기록해 두고 끝까지 비교한다.
        try:
            vllm_identity_before = read_vllm_identity(kubectl)
        except (VllmIdentityError, PreflightFailed) as error:
            raise NotReady([f"vLLM Pod 를 확인하지 못했다({error})"]) from None
        if not vllm_identity_before.ready:
            raise NotReady(
                [
                    f"vLLM Pod {vllm_identity_before.name} 가 Ready 가 아니다(재시작 직후일 수 있다)"
                ]
            )
        plan["vllm_pod"] = asdict(vllm_identity_before)
        write_json(out_dir / "plan.json", plan)
        try:
            vllm_before = read_vllm_counter(kubectl, targets.client)
        except (CounterReadError, subprocess.TimeoutExpired, OSError) as error:
            raise NotReady(
                [f"vLLM 카운터 {VLLM_COUNTER} 를 읽지 못했다({error})"]
            ) from None
        before = read_db_observation(kubectl, targets.primary)
        clock = kubectl.run(
            [
                "exec",
                "-n",
                APP_NAMESPACE,
                targets.client.name,
                "-c",
                API_CONTAINER,
                "--",
                "date",
                "-u",
                "+%s.%N",
            ]
        )
        local_mid = time.time()
        if clock.returncode == 0 and clock.stdout.strip():
            client_epoch = float(clock.stdout.strip())

        observer = threading.Thread(
            target=observe_roles, args=(kubectl, state), daemon=True
        )
        observer.start()
        probe_config = json.dumps(
            {
                "method": inputs.method,
                "path": inputs.path,
                "body": inputs.body,
                "count": inputs.planned_requests,
                "interval_s": inputs.interval_s,
                "timeout_s": inputs.request_timeout_s,
            }
        )
        probe = kubectl.popen(
            ["exec", "-i", "-n", APP_NAMESPACE, targets.client.name, "-c", API_CONTAINER, "--",
             "python3", "-", probe_config]
        )  # fmt: skip
        assert probe.stdin is not None and probe.stdout is not None
        state.probe = probe
        probe.stdin.write(PROBE_SCRIPT)
        probe.stdin.close()
        watcher = threading.Thread(
            target=watch_vllm_counter,
            args=(
                kubectl,
                state,
                targets.client,
                vllm_before,
                vllm_identity_before,
                inputs.gpu_call_cap,
                inputs.llm_counter_poll_s,
            ),
            daemon=True,
        )
        watcher.start()
        timer = threading.Timer(
            inputs.inject_after_s,
            inject_once,
            args=(kubectl, state, targets.primary, out_dir),
        )
        timer.start()

        consecutive_failures = 0
        with (out_dir / "requests.csv").open(
            "w", newline="", encoding="utf-8"
        ) as handle:
            writer = csv.writer(handle)
            # turn_state 는 멀티턴 API가 없는 E0에서는 해당 없음("")이다. 다른 ID와 열을 맞추기 위해 둔다.
            writer.writerow(
                ["utc", "seq", "http", "latency_ms", "error_class", "turn_state"]
            )
            for line in probe.stdout:
                fields = line.rstrip("\n").split(",")
                if (
                    len(fields) < 4
                    or not fields[2].isdigit()
                    or not fields[3].isdigit()
                ):
                    # 측정 출력이 깨졌다. 뭔가 잘못됐으므로 아직 안 보낸 주입은 취소하고 중단한다.
                    aborted, abort_reason = True, "측정 출력 형식 오류"
                    break
                utc, seq, http, latency = fields[:4]
                error = fields[4] if len(fields) > 4 else ""
                writer.writerow([utc, seq, http, latency, error, ""])
                rows.append(
                    {"utc": utc, "seq": seq, "http": http, "latency_ms": latency}
                )
                consecutive_failures = (
                    consecutive_failures + 1 if not 200 <= int(http) < 300 else 0
                )
                if consecutive_failures >= inputs.abort_after_consecutive_failures:
                    # 중단 기준은 사전 입력으로 정해진 값이다. 도달하면 측정기만 멈추고 장애를 추가로 넣지 않는다.
                    aborted, abort_reason = True, "연속 실패 중단 기준 도달"
                    break
        if probe.poll() is None and aborted:
            probe.terminate()
        probe.wait(timeout=KUBECTL_TIMEOUT_S)
        # 감시 스레드가 측정을 멈췄다면 그 이유를 중단 사유로 올린다.
        if state.vllm_replaced:
            aborted, abort_reason = True, "vLLM Pod UID/재시작 변경(관측 불연속)"
        elif state.llm_exceeded:
            aborted, abort_reason = True, "vLLM 카운터 증가량이 상한을 넘음"
        elif state.counter_discontinuity:
            aborted, abort_reason = True, "vLLM 카운터 감소(관측 불연속)"
        elif (
            state.counter_unknown_reads >= MAX_CONSECUTIVE_UNKNOWN_READS and not aborted
        ):
            aborted, abort_reason = True, "vLLM 카운터 읽기 반복 실패"
    except (PreflightFailed, subprocess.TimeoutExpired, OSError, ValueError) as error:
        aborted, abort_reason = True, f"{type(error).__name__}"
        state.problems.append(str(error)[:200])
        if isinstance(error, PreflightFailed):
            raise
    finally:
        # 어떤 경로로 여기 왔든 먼저 주입을 막는다. 락을 잡아서, 지금 막 요청을 보내는 중이면 그 요청이
        # 끝난 뒤에 취소 플래그가 서도록 순서를 보장한다.
        with state.lock:
            state.cancel_injection.set()
        if timer is not None:
            timer.cancel()
        if probe is not None and probe.poll() is None:
            probe.terminate()
            try:
                probe.wait(timeout=5)
            except subprocess.TimeoutExpired:
                probe.kill()
        # 이미 장애가 들어갔다면 회복 관측은 입력의 시한 안에서만 기다린다.
        if observer is not None:
            deadline = time.monotonic() + inputs.recovery_timeout_s
            while (
                state.fault_responded_utc
                and recovery_seconds(state) is None
                and time.monotonic() < deadline
            ):
                time.sleep(POLL_INTERVAL_S)
            state.stop.set()
            observer.join(timeout=POLL_INTERVAL_S * 2)
        if watcher is not None:
            state.stop.set()
            watcher.join(timeout=inputs.llm_counter_poll_s + KUBECTL_TIMEOUT_S)
        if vllm_identity_before is not None:
            try:
                vllm_identity_after = read_vllm_identity(kubectl)
            except (
                VllmIdentityError,
                PreflightFailed,
                subprocess.TimeoutExpired,
                OSError,
                ValueError,
            ):
                vllm_identity_after = "미확인"
        if vllm_before is not None:
            try:
                vllm_after = read_vllm_counter(kubectl, targets.client)
            except (CounterReadError, subprocess.TimeoutExpired, OSError):
                vllm_after = "미확인"
        try:
            current = parse_pods(
                kubectl.get_json(
                    [
                        "get",
                        "pods",
                        "-n",
                        DATA_NAMESPACE,
                        "-l",
                        DB_SELECTOR,
                        "-o",
                        "json",
                    ]
                )
            )
            new_primary = next(
                (p for p in current if p.role == PRIMARY and p.ready), None
            )
            after = (
                read_db_observation(kubectl, new_primary)
                if new_primary
                else {"활동": "미확인(Primary 없음)"}
            )
        except (PreflightFailed, subprocess.TimeoutExpired, json.JSONDecodeError):
            after = {"활동": "미확인(조회 실패)"}

        vllm_increased = (
            isinstance(vllm_after, float)
            and vllm_before is not None
            and vllm_after > vllm_before
        )
        vllm_decreased = (
            isinstance(vllm_after, float)
            and vllm_before is not None
            and vllm_after < vllm_before
        )
        vllm_unknown = vllm_before is not None and not isinstance(vllm_after, float)
        # 카운터가 이전 값 이상으로 보이더라도 Pod 신원이 바뀌었으면 다른 프로세스의 값이다.
        pod_changed = state.vllm_replaced or (
            isinstance(vllm_identity_after, VllmIdentity)
            and vllm_identity_before is not None
            and not same_vllm_process(vllm_identity_before, vllm_identity_after)
        )
        pod_unknown = vllm_identity_before is not None and not isinstance(
            vllm_identity_after, VllmIdentity
        )
        verdict = "수치 기록만(통과/실패 판정 없음)"
        invalid_reasons = []
        if vllm_increased or state.llm_exceeded:
            invalid_reasons.append(
                "vLLM 카운터 증가: 증명된 상한(api 발 호출 없음)이 깨졌거나 다른 LLM 요청이 섞였다"
            )
        if pod_changed:
            invalid_reasons.append(
                "vLLM Pod UID 또는 재시작 횟수가 바뀌었다: 카운터 값과 무관하게 관측이 끊겼다"
            )
        if pod_unknown:
            invalid_reasons.append(
                "vLLM Pod 신원 사후 읽기 실패: 같은 프로세스인지 미확인"
            )
        if vllm_decreased or state.counter_discontinuity:
            invalid_reasons.append("vLLM 카운터 감소: 재시작·리셋으로 관측이 끊겼다")
        if vllm_unknown:
            invalid_reasons.append("vLLM 카운터 사후 읽기 실패: 무효 여부 미확인")
        if state.counter_unknown_reads:
            invalid_reasons.append(
                f"측정 중 카운터 읽기 실패 {state.counter_unknown_reads}회: 해당 구간 미확인"
            )
        if invalid_reasons:
            verdict = "무효 표시"
        summary = {
            "experiment": "E0",
            "verdict": verdict,
            "invalid_reasons": invalid_reasons,
            "aborted": aborted,
            "abort_reason": abort_reason,
            "problems": state.problems,
            "requests": summarize_requests(rows),
            "fault": {
                "requests_sent": state.fault_requests,
                "result": state.fault_result,
                "requested_utc": state.fault_requested_utc,
                "responded_utc": state.fault_responded_utc,
            },
            "recovery_seconds": recovery_seconds(state),
            "measurement_python": python_version,
            "client_clock_offset_s": None
            if client_epoch is None
            else round(client_epoch - local_mid, 3),
            "vllm_pod": {
                "before": asdict(vllm_identity_before)
                if vllm_identity_before
                else None,
                "after": asdict(vllm_identity_after)
                if isinstance(vllm_identity_after, VllmIdentity)
                else vllm_identity_after,
                "changed": pod_changed,
            },
            "vllm_counter": {
                "name": VLLM_COUNTER,
                "before": vllm_before,
                "last_polled": state.counter_last,
                "after": vllm_after,
                "unknown_reads": state.counter_unknown_reads,
            },
            "db_before": before,
            "db_after": after,
            "note": "xact_commit 증가와 pg_stat_activity 는 보조 관측이며 캐시 우회·연결 대상의 완전한 증거가 아니다.",
            "finished_utc": utc_now(),
        }
        write_json(out_dir / "roles.json", state.roles)
        write_json(out_dir / "summary.json", summary)
        write_json(out_dir / "kubectl_calls.json", kubectl.calls)
    return summary


def print_offline_plan(experiment_id: str | None) -> None:
    print("장애 시험 계획(클러스터 접속 없음)")
    for experiment in EXPERIMENTS.values():
        if experiment_id and experiment.id != experiment_id:
            continue
        state = (
            "준비됨(별도 승인·삭제 조건 검증 후 실행 가능)"
            if experiment.ready
            else "준비 안 됨: " + "; ".join(experiment.blocked_by)
        )
        print(
            f"- {experiment.id} {experiment.title}\n    장애: {experiment.fault} (최대 {experiment.max_fault_requests}회)"
            f"\n    판정: {experiment.criterion}\n    상태: {state}"
        )
    print(
        "DB 대상 --run 은 --verify-delete 를 통과한 기록이 있어야 한다. 노드·VM 정지는 --run 대상이 아니다."
    )
    print(OTHER_LLM_TRAFFIC_NOTICE)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--offline", action="store_true", help="계획만 출력(접속 0회). 기본 동작"
    )
    mode.add_argument("--check", action="store_true", help="읽기 전용 사전 점검")
    mode.add_argument(
        "--verify-delete",
        action="store_true",
        help="테스트 네임스페이스에서 삭제 조건 검증",
    )
    mode.add_argument("--run", metavar="ID", help="장애 시험 실행(별도 승인 필요)")
    parser.add_argument("--id", help="--offline/--check 에서 특정 ID만 본다")
    parser.add_argument(
        "--expect-context", help="승인한 kubectl context 이름(모든 호출에 붙는다)"
    )
    parser.add_argument(
        "--confirm",
        help="--run 은 같은 ID, --verify-delete 는 테스트 네임스페이스 이름을 다시 입력",
    )
    parser.add_argument(
        "--target-uid", help="--check 로 확인한 장애 대상 Pod UID(--run 필수)"
    )
    parser.add_argument("--inputs", type=Path, help="E0 사전 입력 JSON 경로")
    parser.add_argument("--out-dir", type=Path, help="결과 기록 디렉터리(새로 만든다)")
    parser.add_argument(
        "--llm-basis",
        type=Path,
        default=DEFAULT_LLM_BASIS,
        help="경로별 LLM 호출 근거 JSON",
    )
    parser.add_argument(
        "--delete-verification",
        type=Path,
        help="--verify-delete 가 남긴 기록(--run 필수)",
    )
    parser.add_argument(
        "--test-namespace",
        help="--verify-delete 의 테스트 네임스페이스(접두어 mafest-fault-test)",
    )
    parser.add_argument(
        "--verification-out", type=Path, help="--verify-delete 기록 저장 경로(새 파일)"
    )
    return parser


def main_verify_delete(args: argparse.Namespace) -> int:
    namespace = args.test_namespace or ""
    if not namespace.startswith(TEST_NAMESPACE_PREFIX) or args.confirm != namespace:
        print(
            f"--test-namespace(접두어 {TEST_NAMESPACE_PREFIX})와 같은 값의 --confirm 이 필요하다.",
            file=sys.stderr,
        )
        return EXIT_USAGE
    if not args.verification_out or args.verification_out.exists():
        print(
            "--verification-out 에 아직 없는 새 파일 경로가 필요하다.", file=sys.stderr
        )
        return EXIT_USAGE
    kubectl = Kubectl(
        args.expect_context,
        frozenset({"get", "create", "delete", "config", "version"}),
        verify_mode_guard(namespace),
    )
    try:
        contexts = kubectl.run(["config", "get-contexts", "-o", "name"]).stdout.split()
        if args.expect_context not in contexts:
            raise PreflightFailed(
                [f"kubeconfig 에 context {args.expect_context!r} 가 없다"]
            )
        record = verify_delete_conditions(kubectl, namespace, args.verification_out)
    except PreflightFailed as failure:
        print("검증을 시작하지 못했다: " + "; ".join(failure.reasons), file=sys.stderr)
        return failure.exit_code
    print(json.dumps(record["cases"], ensure_ascii=False, indent=2))
    print(
        "삭제 조건 검증: "
        + (
            "통과"
            if record["passed"]
            else "실패(원인을 해결하고 다시 검증한다. 우회 경로 없음)"
        )
    )
    return 0 if record["passed"] else EXIT_PRECHECK_FAILED


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not (args.check or args.run or args.verify_delete):
        print_offline_plan(args.id)
        return 0
    if not args.expect_context:
        print(
            "--expect-context 가 필요하다(모든 kubectl 호출에 붙는다).", file=sys.stderr
        )
        return EXIT_USAGE
    if args.verify_delete:
        return main_verify_delete(args)

    experiment_id = args.run or args.id
    experiment = EXPERIMENTS.get(experiment_id) if experiment_id else None
    if args.run and experiment is None:
        print(f"알 수 없는 ID: {args.run}", file=sys.stderr)
        return EXIT_USAGE
    if args.run and not experiment.ready:
        print(
            f"준비 안 됨({experiment.id}): " + "; ".join(experiment.blocked_by),
            file=sys.stderr,
        )
        return EXIT_BLOCKED
    if args.run and args.run != "E0":
        print(f"{args.run} 실행기는 아직 구현하지 않았다.", file=sys.stderr)
        return EXIT_BLOCKED

    inputs = proof = record = None
    if args.run:
        # 사람이 ID와 대상 UID를 직접 다시 입력해야 시작한다. 조건이 하나라도 빠지면 클러스터를 부르지 않는다.
        if (
            args.confirm != args.run
            or not args.target_uid
            or not args.inputs
            or not args.out_dir
        ):
            print(
                "--run 은 --confirm <같은 ID>, --target-uid, --inputs, --out-dir 이 모두 필요하다.",
                file=sys.stderr,
            )
            return EXIT_USAGE
        try:
            routes = load_llm_basis(args.llm_basis)
            inputs, proof = load_e0_inputs(args.inputs, routes)
            if "CHECK-ONLY" in inputs.path:
                # --check 전용 자리표시 id 로 실제 장애 시험을 돌리지 않는다(존재하지 않는 상품 → 404 만 측정된다).
                raise PreflightFailed(
                    [
                        "입력의 상품 id 가 --check 전용 자리표시다. 실제 상품 id 로 바꾼다"
                    ]
                )
            record = load_delete_verification(
                args.delete_verification, args.expect_context
            )
        except PreflightFailed as failure:
            print(
                "준비 안 됨/입력 부족: " + "; ".join(failure.reasons), file=sys.stderr
            )
            return failure.exit_code

    # --check 는 get/config/version 만, --run 은 관측용 exec 와 (가드된) delete 까지 허용한다. debug 는 어느 쪽에도 없다.
    if args.run:
        kubectl = Kubectl(
            args.expect_context,
            frozenset({"get", "config", "version", "exec", "delete"}),
            run_mode_guard,
        )
    else:
        kubectl = Kubectl(args.expect_context, frozenset({"get", "config", "version"}))
    try:
        targets = preflight(kubectl, args.expect_context)
        if args.run:
            check_proof_context(proof, targets.api_pods)
            check_record_versions(record, version_fingerprint(kubectl))
    except PreflightFailed as failure:
        print("사전 점검 실패: " + "; ".join(failure.reasons), file=sys.stderr)
        return failure.exit_code

    if args.check:
        print(f"사전 점검 통과(context {targets.context})")
        print(
            f"  장애 대상 후보: {targets.primary.name} uid={targets.primary.uid}"
            f" node={targets.primary.node} role={targets.primary.role}"
        )
        print(f"  측정용 api Pod: {targets.client.name} node={targets.client.node}")
        fingerprint = tool_fingerprint(args.llm_basis)
        print(f"  도구 sha256: mafest_fault.py={fingerprint['mafest_fault_py_sha256']}")
        print(
            f"               llm-call-basis.json={fingerprint['llm_call_basis_json_sha256']}"
        )
        print(
            "  이 UID를 --run 의 --target-uid 로 사용한다. 승인 전에는 아무것도 변경하지 않았다."
        )
        try:
            vllm_now = read_vllm_identity(kubectl)
        except (VllmIdentityError, PreflightFailed) as error:
            print(f"  vLLM Pod 확인 불가: {error}", file=sys.stderr)
            return EXIT_PRECHECK_FAILED
        print(
            f"  vLLM Pod: {vllm_now.name} uid={vllm_now.uid} 재시작={vllm_now.restart_count}"
            f" Ready={vllm_now.ready} (측정 중 UID·재시작 횟수가 바뀌면 중단한다)"
        )
        if not vllm_now.ready:
            print(
                "  vLLM Pod 가 Ready 가 아니다. 이 상태로는 E0를 시작할 수 없다.",
                file=sys.stderr,
            )
            return EXIT_BLOCKED
        running = sorted({p.image_digest or "읽을 수 없음" for p in targets.api_pods})
        print(f"  실행 중인 api 이미지 digest: {', '.join(running)}")
        if args.inputs:
            try:
                routes = load_llm_basis(args.llm_basis)
                checked_inputs, checked = load_e0_inputs(args.inputs, routes)
                for warning in input_warnings(checked_inputs):
                    print(f"  경고: {warning}", file=sys.stderr)
                check_proof_context(checked, targets.api_pods)
            except PreflightFailed as failure:
                print("  E0 준비 안 됨: " + "; ".join(failure.reasons), file=sys.stderr)
                return failure.exit_code
            print(
                f"  LLM 호출 상한 증명 유효: {checked.pattern} 상한 {checked.llm_call_upper_bound}회"
                f" (digest 일치, 검토 커밋 {checked.reviewed_commit[:8]})"
            )
            if not checked.provenance_verified:
                print(
                    "  주의: 이미지 digest ↔ 커밋 대응은 배포 매니페스트 주석 기준이며 빌드 출처는 검증하지 못했다."
                )
        else:
            print("  (--inputs 를 주면 E0 입력과 LLM 호출 상한 증명을 함께 점검한다)")
        print("  참고: --run 전에 통과한 --verify-delete 기록이 필요하다.")
        print("  " + OTHER_LLM_TRAFFIC_NOTICE)
        return 0

    # 요청 직전 재확인(1차): 승인한 UID가 지금도 Primary여야 한다. 주입 직전에 한 번 더 확인한다(inject_once).
    if targets.primary.uid != args.target_uid:
        print(
            "승인한 UID가 현재 Primary가 아니다. 장애를 넣지 않고 중단한다.",
            file=sys.stderr,
        )
        return EXIT_PRECHECK_FAILED
    print(OTHER_LLM_TRAFFIC_NOTICE, file=sys.stderr)
    for warning in input_warnings(inputs):
        print(f"경고: {warning}", file=sys.stderr)
    if not proof.provenance_verified:
        print(
            "주의: 이미지 digest ↔ 커밋 대응은 배포 매니페스트 주석 기준이며 빌드 출처는 검증하지 못했다.",
            file=sys.stderr,
        )
    try:
        summary = run_e0(kubectl, targets, inputs, proof, args.out_dir, args.llm_basis)
    except PreflightFailed as failure:
        print("시작 전 중단: " + "; ".join(failure.reasons), file=sys.stderr)
        return failure.exit_code
    print(
        json.dumps(
            {
                k: summary[k]
                for k in (
                    "verdict",
                    "invalid_reasons",
                    "aborted",
                    "requests",
                    "fault",
                    "recovery_seconds",
                )
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
