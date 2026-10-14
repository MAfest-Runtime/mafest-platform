"""멀티턴 준비 초안(deploy/mafest-multiturn)의 정적 검사기.

클러스터에 접속하지 않는다. `kubectl kustomize`는 로컬 렌더만 하며 API server를 부르지 않는다.
실행: python3 -I scripts/check_mafest_multiturn_prep.py [--require-complete]

검사 범위
- 초안이 어떤 prod 렌더에도 들어가지 않는다(.draft 확장자 + kustomization 미연결).
- Job/CronJob 초안마다 egress·DB ingress NetworkPolicy가 짝으로 있고, 기존 허용 라벨을 재사용하지 않는다.
- 정리 CronJob은 suspend이고 삭제 SQL·LIMIT 삭제를 담지 않는다.
- 권한 템플릿은 GRANT만 쓰고 넓은 권한·DDL을 담지 않는다.
- 기존 API 종료 시간 선언이 부등식을 지킨다(변경하지 않고 읽기만).
- 새 파일에 비밀번호·DSN 원문 형태가 없다.
- 앱이 채워야 할 자리표시가 남아 있으면 "준비 미완료"로 보고한다(--require-complete면 실패).
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

# 시험이 변형한 사본을 검사할 수 있도록 저장소 위치를 환경변수로 바꿀 수 있다.
REPO = Path(os.environ.get("MAFEST_PREP_REPO", Path(__file__).resolve().parent.parent))
DRAFT_DIR = REPO / "deploy" / "mafest-multiturn" / "drafts"
PROD_OVERLAYS = (
    "mafest-app",
    "mafest-app-netpol",
    "mafest-db",
    "mafest-db-netpol",
    "mafest-load",
)
# 기존 허용 라벨. 새 워크로드가 이 라벨을 쓰면 기존 정책이 의도치 않게 새 Pod에 적용된다.
EXISTING_ALLOWED_LABELS = {"mafest-api", "mafest-loader"}
DRAFT_NAME_PREFIX = "mafest-session"
PLACEHOLDER = re.compile(r"__[A-Z0-9_]+__")
ZERO_DIGEST = re.compile(r"@sha256:0{64}\b")
# 비밀 형태: URL 안의 user:password@, `password:` 뒤 값, 긴 base64 덩어리.
SECRET_PATTERNS = (
    re.compile(r"postgres(?:ql)?://[^\s/@:]+:[^\s/@]+@"),
    re.compile(r"(?i)\bpassword\s*[:=]\s*[\"']?[^\s\"'<>$]{4,}"),
    re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/])"),
)
# 부등식에 쓰는 기존 선언의 위치. 값은 매니페스트에서 읽는다.
API_DEPLOYMENT = REPO / "kustomize/base/mafest-app/api-deployment.yaml"
# 합의 전 후보값. 장애 감지 보장이 아니라 "여유를 둔 설정인가"만 본다.
CANDIDATE_RENEW_S = 10
CANDIDATE_LEASE_TTL_S = 30

failures: list[str] = []
notes: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def load_drafts() -> list[dict]:
    documents: list[dict] = []
    for path in sorted(DRAFT_DIR.glob("*.yaml.draft")):
        for document in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if document:
                document["_file"] = path.name
                documents.append(document)
    return documents


def check_not_rendered() -> None:
    """초안이 prod 렌더에 들어가지 않고 kustomization에서 참조되지도 않는다."""
    for overlay in PROD_OVERLAYS:
        rendered = subprocess.run(
            ["kubectl", "kustomize", str(REPO / "kustomize/overlays/prod" / overlay)],
            capture_output=True,
            text=True,
            check=False,
        )
        if rendered.returncode != 0:
            fail(f"[렌더] {overlay} 렌더 실패: {rendered.stderr.strip()[:200]}")
            continue
        if (
            DRAFT_NAME_PREFIX in rendered.stdout
            or "mafest-allow-migrate-egress" in rendered.stdout
        ):
            fail(f"[안전] 초안 리소스가 prod 렌더({overlay})에 들어갔다")
    for kustomization in REPO.glob("kustomize/**/kustomization.yaml"):
        if "mafest-multiturn" in kustomization.read_text(encoding="utf-8"):
            fail(f"[안전] {kustomization.relative_to(REPO)} 가 멀티턴 초안을 참조한다")


def pod_labels(document: dict) -> dict:
    spec = document["spec"]
    template = (
        spec["jobTemplate"]["spec"]["template"]
        if document["kind"] == "CronJob"
        else spec["template"]
    )
    return template["metadata"]["labels"]


def pod_spec(document: dict) -> dict:
    spec = document["spec"]
    template = (
        spec["jobTemplate"]["spec"]["template"]
        if document["kind"] == "CronJob"
        else spec["template"]
    )
    return template["spec"]


def check_workloads_and_policies(documents: list[dict]) -> None:
    workloads = [d for d in documents if d["kind"] in ("Job", "CronJob")]
    policies = [d for d in documents if d["kind"] == "NetworkPolicy"]
    if not workloads:
        fail("[구성] Job/CronJob 초안이 없다")
    for workload in workloads:
        name = workload["metadata"]["name"]
        label = pod_labels(workload)["app.kubernetes.io/name"]
        spec = pod_spec(workload)
        if label in EXISTING_ALLOWED_LABELS:
            fail(f"[안전] {name}: 기존 허용 라벨 {label} 을 재사용한다")
        if spec.get("automountServiceAccountToken") is not False:
            fail(f"[안전] {name}: API 토큰 자동 마운트를 끄지 않았다")
        context = spec.get("securityContext", {})
        if context.get("runAsNonRoot") is not True:
            fail(f"[안전] {name}: runAsNonRoot 가 아니다")
        container = spec["containers"][0]
        if (
            "limits" not in container.get("resources", {})
            or "requests" not in container["resources"]
        ):
            fail(f"[안전] {name}: requests/limits 가 없다")
        if workload["kind"] == "Job" and workload["spec"].get("backoffLimit") != 0:
            fail(f"[안전] {name}: backoffLimit 이 0이 아니다")
        if (
            workload["kind"] == "CronJob"
            and workload["spec"].get("suspend") is not True
        ):
            fail(f"[안전] {name}: 정리 CronJob 초안이 suspend 가 아니다")

        selects = [
            p
            for p in policies
            if p["spec"]
            .get("podSelector", {})
            .get("matchLabels", {})
            .get("app.kubernetes.io/name")
            == label
        ]
        egress = [p for p in selects if "Egress" in p["spec"].get("policyTypes", [])]
        if not egress:
            fail(f"[짝] {name}: 라벨 {label} 에 대응하는 egress NetworkPolicy 가 없다")
        else:
            ports = {
                (rule_port.get("protocol"), rule_port.get("port"))
                for p in egress
                for rule in p["spec"]["egress"]
                for rule_port in rule["ports"]
            }
            if ("UDP", 53) not in ports or ("TCP", 5432) not in ports:
                fail(f"[짝] {name}: egress 에 DNS(53)와 DB(5432)가 모두 필요하다")
        db_ingress = [
            p
            for p in policies
            if p["spec"]
            .get("podSelector", {})
            .get("matchLabels", {})
            .get("cnpg.io/cluster")
            == "mafest-db"
            and "Ingress" in p["spec"].get("policyTypes", [])
            and any(
                peer.get("podSelector", {})
                .get("matchLabels", {})
                .get("app.kubernetes.io/name")
                == label
                for rule in p["spec"].get("ingress", [])
                for peer in rule["from"]
            )
        ]
        if not db_ingress:
            fail(f"[짝] {name}: DB 쪽 ingress 정책이 라벨 {label} 을 허용하지 않는다")
    for policy in policies:
        # 넓은 허용(빈 selector, 0.0.0.0/0)을 막는다.
        text = yaml.safe_dump(policy["spec"])
        if "ipBlock" in text or "{}" in text.replace("podSelector: {}", "X"):
            fail(
                f"[안전] {policy['metadata']['name']}: 넓은 허용으로 보이는 선언이 있다"
            )


def check_cleanup_has_no_delete_sql(documents: list[dict]) -> None:
    for document in documents:
        text = Path(DRAFT_DIR / document["_file"]).read_text(encoding="utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if re.search(r"(?i)\bDELETE\b", line) or re.search(r"(?i)\bLIMIT\b", line):
                fail(
                    f"[계약] {document['_file']}:{number} 정리 계약 확정 전인데 삭제 SQL 형태가 있다"
                )


def check_grants_template() -> None:
    path = DRAFT_DIR / "session-role-grants.sql.tmpl"
    lines = [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("--")
    ]
    code = "\n".join(lines)
    for forbidden, reason in (
        (r"(?i)\bALL\s+PRIVILEGES\b", "넓은 권한"),
        (r"(?i)\bALL\s+TABLES\s+IN\s+SCHEMA\b", "스키마 전체 권한"),
        (r"(?i)\b(CREATE|DROP|ALTER|TRUNCATE)\b(?!\s*,)", "DDL"),
        (r"(?i)\bSUPERUSER\b|\bCREATEROLE\b", "높은 role 속성"),
        (r"(?i)ag_catalog", "AGE 스키마"),
        (r"(?i)\bGRANT\s+CREATE\b", "CREATE 권한"),
    ):
        if re.search(forbidden, code):
            fail(f"[권한] 템플릿에 금지 항목({reason})이 있다")
    if "mafest_runtime" in code and "RAISE EXCEPTION" not in code:
        fail("[권한] 템플릿이 mafest_runtime 을 다룬다")
    if "'mafest_runtime'" not in code:
        fail("[권한] 템플릿이 mafest_runtime 을 대상에서 막지 않는다")


def check_timing_budget() -> None:
    """기존 API 종료 시간 선언을 읽어 부등식을 확인한다. 선언은 바꾸지 않는다."""
    deployment = yaml.safe_load(API_DEPLOYMENT.read_text(encoding="utf-8"))
    pod = deployment["spec"]["template"]["spec"]
    container = pod["containers"][0]
    env = {item["name"]: item.get("value") for item in container["env"]}
    args = container["args"]
    graceful = int(args[args.index("--timeout-graceful-shutdown") + 1])
    pre_stop = int(container["lifecycle"]["preStop"]["exec"]["command"][1])
    llm = int(env["MAFEST_LLM_TIMEOUT_S"])
    request = int(env["MAFEST_REQUEST_TIMEOUT_S"])
    grace = int(pod["terminationGracePeriodSeconds"])
    if not llm < request < graceful:
        fail(f"[종료] LLM({llm}) < 요청({request}) < graceful({graceful}) 이 깨졌다")
    if not pre_stop + graceful < grace:
        fail(
            f"[종료] preStop({pre_stop}) + graceful({graceful}) < 유예({grace}) 가 깨졌다"
        )
    if not 2 * CANDIDATE_RENEW_S < CANDIDATE_LEASE_TTL_S:
        fail("[lease] 후보 갱신 주기×2 가 lease TTL 이상이다")
    notes.append(
        f"종료 선언: LLM {llm} < 요청 {request} < graceful {graceful}, preStop {pre_stop}+{graceful} < 유예 {grace}. "
        f"lease 후보 {CANDIDATE_RENEW_S}×2 < {CANDIDATE_LEASE_TTL_S} 은 여유 조건일 뿐 감지 보장이 아니다."
    )


def check_no_secret_shapes() -> None:
    targets = list(DRAFT_DIR.iterdir()) + [
        REPO / "scripts/mafest_sync_db_secret.py",
        REPO / "scripts/check_mafest_multiturn_prep.py",
        REPO / "deploy/mafest-multiturn/README.md",
    ]
    for path in targets:
        if not path.exists() or path.name == "check_mafest_multiturn_prep.py":
            continue  # 이 파일은 패턴 정의 자체를 담는다
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            scrubbed = re.sub(r"sha256:[0-9a-f]{64}", "", line)
            for pattern in SECRET_PATTERNS:
                if pattern.search(scrubbed):
                    fail(
                        f"[비밀] {path.relative_to(REPO)}:{number} 비밀값 형태가 보인다"
                    )


def check_kubectl_single_gateway() -> None:
    """kubectl 을 실행하는 모든 subprocess 호출이 `--context` 를 붙이는 한 관문을 지나는지 AST 로 본다.

    - 장애 도구: subprocess.run/Popen 의 첫 인자가 반드시 `self.argv(...)`(Kubectl 래퍼) 여야 한다.
    - Secret 전달 도구: 첫 인자 리스트에 문자열 "--context" 가 들어 있어야 한다.
    """
    targets = {
        "scripts/fault/mafest_fault.py": "wrapper",
        "scripts/mafest_sync_db_secret.py": "literal",
    }
    for relative, style in targets.items():
        path = REPO / relative
        if not path.exists():
            fail(f"[context] {relative} 가 없다")
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if not (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr in ("run", "Popen")
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "subprocess"
            ):
                continue
            first = node.args[0] if node.args else None
            if style == "wrapper":
                ok = (
                    isinstance(first, ast.Call)
                    and isinstance(first.func, ast.Attribute)
                    and first.func.attr == "argv"
                )
            else:
                ok = isinstance(first, ast.List) and any(
                    isinstance(item, ast.Constant) and item.value == "--context"
                    for item in first.elts
                )
            if not ok:
                fail(
                    f"[context] {relative}:{node.lineno} kubectl 호출이 --context 관문을 지나지 않는다"
                )


def check_unchanged_runtime_paths() -> None:
    """기존 배포·정책·권한 파일을 이 작업이 바꾸지 않았다."""
    diff = subprocess.run(
        ["git", "diff", "--name-only", "HEAD", "--", "kustomize", "argocd", "db"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    changed = [line for line in diff.stdout.splitlines() if line]
    if changed:
        fail(f"[범위] 기존 선언이 바뀌었다: {', '.join(changed)}")


def report_completeness() -> bool:
    missing: dict[str, set[str]] = {}
    for path in sorted(DRAFT_DIR.iterdir()):
        text = path.read_text(encoding="utf-8")
        found = {
            m
            for line in text.splitlines()
            if not line.lstrip().startswith("#")
            for m in PLACEHOLDER.findall(line)
        }
        if ZERO_DIGEST.search(text):
            found.add("이미지 digest(0 자리표시)")
        if found:
            missing[path.name] = found
    basis_path = REPO / "scripts/fault/llm-call-basis.json"
    if basis_path.exists():
        routes = json.loads(basis_path.read_text(encoding="utf-8")).get("routes", {})
        usable = []
        for route, entry in routes.items():
            proof = entry.get("proof") or {}
            if entry.get("llm_call_upper_bound") is None:
                notes.append(
                    f"E0 대상 제외: {route} — LLM 호출 지점에 도달 가능해 상한을 정할 수 없다"
                )
                continue
            usable.append(route)
            if not proof.get("provenance_verified"):
                notes.append(
                    f"미검증: {route} 증명의 이미지 digest ↔ 커밋 대응(빌드 출처)은 확인하지 못했다"
                )
        if not usable:
            missing.setdefault("scripts/fault/llm-call-basis.json", set()).add(
                "LLM 호출 상한이 증명된 경로가 없다"
            )
    for name, items in missing.items():
        notes.append(f"준비 미완료: {name} — {', '.join(sorted(items))}")
    return not missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="자리표시가 남아 있으면 실패한다",
    )
    args = parser.parse_args()

    documents = load_drafts()
    check_not_rendered()
    check_workloads_and_policies(documents)
    check_cleanup_has_no_delete_sql(documents)
    check_grants_template()
    check_timing_budget()
    check_no_secret_shapes()
    check_kubectl_single_gateway()
    check_unchanged_runtime_paths()
    complete = report_completeness()
    if args.require_complete and not complete:
        fail("[미완료] 앱이 확정할 값이 남아 있다")

    for note in notes:
        print(note)
    for message in failures:
        print(f"실패: {message}", file=sys.stderr)
    print(
        "정적 검사 "
        + ("실패" if failures else "통과")
        + f" (실패 {len(failures)}건, 준비 {'완료' if complete else '미완료'})"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
