"""마이그레이션 → API 선택 Sync 순서 절차와 그 검사기.

이 모듈은 절차를 "코드로 고정"해 두고 가짜 실행기로 시험하기 위한 것이다. 이번 범위에서는 실제 클러스터에
연결하지 않는다. CLI는 계획 출력(--offline)만 지원하고 실행 모드는 일부러 만들지 않았다.

순서를 hook/wave에 맡기지 않는 이유: Argo CD의 선택 Sync는 hook을 실행하지 않고, 서로 다른 Application 사이의
wave 숫자는 선행을 보장하지 않는다. 그래서 사람이 Job을 따로 만들고 결과를 확인한 뒤에만 API Sync를 요청한다.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable
from dataclasses import dataclass, field

JOB_COMPLETE = "Complete"
JOB_FAILED = "Failed"


@dataclass
class DeployInputs:
    """앱이 확정해 준 입력. 하나라도 비어 있으면 아무 명령도 보내지 않는다."""

    migration_image_digest: str
    expected_migration_version: str
    migration_job_manifest: str
    api_sync_resource: str = "apps:Deployment:mafest-app/mafest-api"

    def missing(self) -> list[str]:
        names = []
        if not self.migration_image_digest or set(
            self.migration_image_digest.split("sha256:")[-1]
        ) == {"0"}:
            names.append("migration_image_digest")
        if not self.expected_migration_version:
            names.append("expected_migration_version")
        if not self.migration_job_manifest:
            names.append("migration_job_manifest")
        return names


@dataclass
class Runner:
    """클러스터 명령을 대신 실행하는 자리. 시험에서는 가짜로 바꾼다."""

    create_job: Callable[[str], None]
    job_state: Callable[[], str]
    read_applied_version: Callable[[], str | None]
    sync_api: Callable[[str], None]


@dataclass
class Outcome:
    executed: list[str] = field(default_factory=list)
    stopped_reason: str | None = None

    @property
    def synced(self) -> bool:
        return "sync_api" in self.executed


def run_sequence(inputs: DeployInputs, runner: Runner) -> Outcome:
    """순서대로 진행하고 어느 단계든 실패하면 그 자리에서 멈춘다. 재시도하지 않는다."""
    outcome = Outcome()
    missing = inputs.missing()
    if missing:
        outcome.stopped_reason = f"입력 미확정: {', '.join(missing)}"
        return outcome

    runner.create_job(inputs.migration_job_manifest)
    outcome.executed.append("create_job")

    state = runner.job_state()
    outcome.executed.append("wait_job")
    if state != JOB_COMPLETE:
        outcome.stopped_reason = f"마이그레이션 Job 상태가 {state!r} 이다"
        return outcome

    applied = runner.read_applied_version()
    outcome.executed.append("verify_version")
    if applied is None:
        outcome.stopped_reason = (
            "적용된 마이그레이션 버전을 읽지 못했다(미확인은 통과가 아니다)"
        )
        return outcome
    if applied != inputs.expected_migration_version:
        outcome.stopped_reason = "마이그레이션 버전이 기대와 다르다"
        return outcome

    runner.sync_api(inputs.api_sync_resource)
    outcome.executed.append("sync_api")
    return outcome


PLAN = (
    "1. 앱이 확정한 입력(이미지 digest·마이그레이션 버전) 확인 — 비어 있으면 중단",
    "2. 마이그레이션 Job을 별도로 생성(Argo hook이 아니다)",
    "3. Job이 Complete가 될 때까지 확인 — Failed·시간 초과면 중단, 재시도 없음",
    "4. 적용된 마이그레이션 버전과 role 권한 확인 — 읽지 못하거나 다르면 중단",
    "5. 위가 모두 통과한 뒤에만 API 선택 Sync 요청(--resource 로 mafest-api Deployment 한 건)",
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--offline", action="store_true", help="계획만 출력한다(기본 동작과 같다)"
    )
    parser.parse_args(argv)
    print("배포 순서 계획(클러스터 접속 없음, 실행 모드 없음):")
    for line in PLAN:
        print("  " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
