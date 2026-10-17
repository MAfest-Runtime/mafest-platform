"""멀티턴 준비 초안(deploy/mafest-multiturn)의 정적 검사기.

클러스터에 접속하지 않는다. `kubectl kustomize`는 로컬 렌더만 하며 API server를 부르지 않는다.
실행: python3 -I scripts/check_mafest_multiturn_prep.py [--require-complete]

검사 범위
- 초안이 어떤 prod 렌더에도 들어가지 않는다(.draft 확장자 + kustomization 미연결).
- Job/CronJob 초안마다 egress·DB ingress NetworkPolicy가 짝으로 있고, 기존 허용 라벨을 재사용하지 않는다.
  예외는 세션 마이그레이션 Job 하나뿐이다. 적재 Job 패턴을 그대로 써서 기존 loader 정책을 의도적으로 재사용하며,
  라벨이 정확히 mafest-loader 이고 기존 정책이 실제로 있을 때만 통과한다.
- 세션 마이그레이션 Job은 상품 owner 계열 Secret(mafest-migrator·mafest-db-owner)이 아니라 전용 Secret만 쓴다.
- README §11 과 db/grants 의 kubectl 명령은 --context 와 -n/--namespace 를 모두 적는다(터미널 기본값에 의존하지 않는다).
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
# 기존 적재 Job 라벨을 의도적으로 재사용하는 워크로드. 기존 mafest-allow-loader-egress(DNS·DB 5432)와
# mafest-allow-db-ingress(mafest-loader 허용)가 이미 필요한 만큼만 열어 주므로 새 정책을 만들지 않는다.
LOADER_REUSING_WORKLOADS = {"mafest-session-migrate": "mafest-loader"}
LOADER_EGRESS_POLICY = "mafest-allow-loader-egress"
DB_INGRESS_POLICY = "mafest-allow-db-ingress"
# 세션 마이그레이션 Job 의 DDL 자격. 상품 owner 의 전역 기본 권한이 새 세션 테이블을 검색 계정에 열어 주므로
# owner 계열 Secret 을 쓰지 않고 세션 전용 역할(mafest_session_migrator)의 DSN 만 쓴다.
MIGRATION_JOB_NAME = "mafest-session-migrate"
MIGRATION_SECRET = "mafest-session-migrate-db"
PRODUCT_OWNER_SECRETS = ("mafest-migrator", "mafest-db-owner")
README_OPS_HEADING = "## 11."
CODE_SPAN = re.compile(r"`([^`]*)`")
# 이 작업이 의도적으로 바꾸는 기존 선언. 이 밖의 kustomize·argocd·db 변경은 여전히 실패다.
INTENDED_CHANGES = {
    "db/grants/mafest_roles.sql",
    "kustomize/base/mafest-app/api-deployment.yaml",
    "kustomize/base/mafest-db/cluster.yaml",
    "kustomize/base/mafest-load/kustomization.yaml",
}
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


def secret_refs(document: dict) -> set[str]:
    """워크로드 Pod 가 환경변수로 참조하는 Secret 이름들(secretKeyRef·envFrom)."""
    names: set[str] = set()
    for container in pod_spec(document).get("containers", []):
        for item in container.get("env", []):
            reference = (item.get("valueFrom") or {}).get("secretKeyRef")
            if reference:
                names.add(reference["name"])
        for source in container.get("envFrom", []):
            if "secretRef" in source:
                names.add(source["secretRef"]["name"])
    return names


def check_migration_credentials(documents: list[dict]) -> None:
    """마이그레이션 Job 은 상품 owner 계열 Secret 을 쓰지 않고 세션 전용 Secret 을 쓴다."""
    jobs = [
        d
        for d in documents
        if d["kind"] == "Job" and d["metadata"]["name"] == MIGRATION_JOB_NAME
    ]
    if not jobs:
        fail(f"[구성] {MIGRATION_JOB_NAME} Job 초안이 없다")
        return
    references = secret_refs(jobs[0])
    for forbidden in PRODUCT_OWNER_SECRETS:
        if forbidden in references:
            fail(
                f"[권한] {MIGRATION_JOB_NAME}: 상품 owner 계열 Secret {forbidden} 을 쓴다 — "
                "owner 의 전역 기본 권한이 새 세션 테이블을 검색 계정에 연다"
            )
    if MIGRATION_SECRET not in references:
        fail(
            f"[권한] {MIGRATION_JOB_NAME}: 세션 전용 Secret {MIGRATION_SECRET} 을 쓰지 않는다"
        )


def check_ops_commands() -> None:
    """운영 kubectl 명령은 --context 와 -n/--namespace 를 직접 적는다. README §11 코드 조각과 db/grants 주석을 본다."""
    sources: list[tuple[str, str, bool]] = []
    readme = REPO / "deploy/mafest-multiturn/README.md"
    if readme.exists():
        text = readme.read_text(encoding="utf-8")
        if README_OPS_HEADING in text:
            sources.append(("README §11", text[text.index(README_OPS_HEADING) :], True))
    for path in sorted((REPO / "db/grants").glob("*.sql")):
        sources.append(
            (str(path.relative_to(REPO)), path.read_text(encoding="utf-8"), False)
        )
    for label, body, markdown in sources:
        for number, line in enumerate(body.splitlines(), 1):
            commands = (
                [span for span in CODE_SPAN.findall(line) if "kubectl" in span]
                if markdown
                else ([line] if "kubectl" in line else [])
            )
            for command in commands:
                has_context = re.search(r"--context[ =]\S+", command)
                has_namespace = re.search(r"(?:^|\s)(?:-n|--namespace)[ =]\S+", command)
                if not (has_context and has_namespace):
                    fail(
                        f"[명령] {label}:{number} kubectl 명령에 --context 와 -n/--namespace 가 모두 있어야 한다"
                    )


def loader_policies_exist() -> bool:
    """기존 loader egress 정책(DNS·DB 5432)과 DB ingress 정책(mafest-loader 허용)이 선언돼 있는가."""
    found: dict[str, dict] = {}
    for path in REPO.glob("kustomize/base/networkpolicy/mafest-*/network-policy.yaml"):
        for document in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if document and document.get("kind") == "NetworkPolicy":
                found[document["metadata"]["name"]] = document
    egress = found.get(LOADER_EGRESS_POLICY)
    ingress = found.get(DB_INGRESS_POLICY)
    if egress is None or ingress is None:
        return False
    selects_loader = (
        egress["spec"]
        .get("podSelector", {})
        .get("matchLabels", {})
        .get("app.kubernetes.io/name")
        == "mafest-loader"
    )
    ports = {
        (port.get("protocol"), port.get("port"))
        for rule in egress["spec"].get("egress", [])
        for port in rule.get("ports", [])
    }
    allows_loader = any(
        peer.get("podSelector", {}).get("matchLabels", {}).get("app.kubernetes.io/name")
        == "mafest-loader"
        for rule in ingress["spec"].get("ingress", [])
        for peer in rule.get("from", [])
    )
    return selects_loader and ("TCP", 5432) in ports and allows_loader


def check_workloads_and_policies(documents: list[dict]) -> None:
    workloads = [d for d in documents if d["kind"] in ("Job", "CronJob")]
    policies = [d for d in documents if d["kind"] == "NetworkPolicy"]
    if not workloads:
        fail("[구성] Job/CronJob 초안이 없다")
    for workload in workloads:
        name = workload["metadata"]["name"]
        label = pod_labels(workload)["app.kubernetes.io/name"]
        spec = pod_spec(workload)
        reused_label = LOADER_REUSING_WORKLOADS.get(name)
        if reused_label is None and label in EXISTING_ALLOWED_LABELS:
            fail(f"[안전] {name}: 기존 허용 라벨 {label} 을 재사용한다")
        if reused_label is not None and label != reused_label:
            fail(
                f"[안전] {name}: 기존 loader 정책을 재사용하려면 라벨이 {reused_label} 이어야 한다(실제 {label})"
            )
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

        if reused_label is not None:
            # 새 정책을 만들지 않는 대신 기존 정책이 실제로 있고 loader 를 허용하는지 확인한다.
            if not loader_policies_exist():
                fail(
                    f"[짝] {name}: 재사용할 기존 정책({LOADER_EGRESS_POLICY}, {DB_INGRESS_POLICY})을 찾지 못했다"
                )
            continue
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
    notes.append(
        f"종료 선언: LLM {llm} < 요청 {request} < graceful {graceful}, preStop {pre_stop}+{graceful} < 유예 {grace}. "
        "세션 lease 는 앱 코드가 정한다(요청 시한 + 10초). 선언에서 따로 두지 않는다."
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
            # 쿠버네티스 필드 이름(긴 영문 한 단어)이 긴 base64 형태 검사에 걸리지 않게 한다.
            scrubbed = scrubbed.replace(
                "requiredDuringSchedulingIgnoredDuringExecution", ""
            )
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
    """이 작업이 의도적으로 바꾸는 파일(INTENDED_CHANGES) 밖의 기존 배포·정책·권한 파일을 바꾸지 않았다."""
    diff = subprocess.run(
        ["git", "diff", "--name-only", "HEAD", "--", "kustomize", "argocd", "db"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
    )
    changed = [
        line
        for line in diff.stdout.splitlines()
        if line and line not in INTENDED_CHANGES
    ]
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
    check_migration_credentials(documents)
    check_ops_commands()
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
