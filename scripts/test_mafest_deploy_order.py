"""배포 순서 검사기를 가짜 실행기로 시험한다. 클러스터에 접속하지 않는다.

실행: python3 -I scripts/test_mafest_deploy_order.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mafest_deploy_order import (
    JOB_COMPLETE,
    JOB_FAILED,
    DeployInputs,
    Runner,
    run_sequence,
)  # noqa: E402

REAL_LOOKING_DIGEST = "ghcr.io/example/app@sha256:" + "ab" * 32


def make_inputs(**overrides: str) -> DeployInputs:
    values = {
        "migration_image_digest": REAL_LOOKING_DIGEST,
        "expected_migration_version": "v-test-1",
        "migration_job_manifest": "job.yaml",
    }
    values.update(overrides)
    return DeployInputs(**values)


class Recorder:
    """호출 기록을 남기는 가짜 실행기."""

    def __init__(
        self, job_state: str = JOB_COMPLETE, applied: str | None = "v-test-1"
    ) -> None:
        self.calls: list[str] = []
        self.sync_arguments: list[str] = []
        self._job_state = job_state
        self._applied = applied

    def runner(self) -> Runner:
        return Runner(
            create_job=lambda manifest: self.calls.append("create_job"),
            job_state=lambda: self.calls.append("job_state") or self._job_state,
            read_applied_version=lambda: (
                self.calls.append("read_version") or self._applied
            ),
            sync_api=lambda resource: (
                self.calls.append("sync_api"),
                self.sync_arguments.append(resource),
            ),
        )


class DeployOrderTest(unittest.TestCase):
    def test_incomplete_inputs_send_no_command(self) -> None:
        recorder = Recorder()
        outcome = run_sequence(
            make_inputs(expected_migration_version=""), recorder.runner()
        )
        self.assertEqual(recorder.calls, [])
        self.assertIsNotNone(outcome.stopped_reason)

    def test_placeholder_zero_digest_counts_as_missing(self) -> None:
        recorder = Recorder()
        run_sequence(
            make_inputs(migration_image_digest="app@sha256:" + "0" * 64),
            recorder.runner(),
        )
        self.assertEqual(recorder.calls, [])

    def test_failed_migration_job_does_not_request_sync(self) -> None:
        recorder = Recorder(job_state=JOB_FAILED)
        outcome = run_sequence(make_inputs(), recorder.runner())
        self.assertNotIn("sync_api", recorder.calls)
        self.assertFalse(outcome.synced)

    def test_unreadable_version_does_not_request_sync(self) -> None:
        recorder = Recorder(applied=None)
        outcome = run_sequence(make_inputs(), recorder.runner())
        self.assertNotIn("sync_api", recorder.calls)
        self.assertFalse(outcome.synced)

    def test_version_mismatch_does_not_request_sync(self) -> None:
        recorder = Recorder(applied="v-other")
        outcome = run_sequence(make_inputs(), recorder.runner())
        self.assertNotIn("sync_api", recorder.calls)
        self.assertFalse(outcome.synced)

    def test_success_syncs_only_api_once_after_all_checks(self) -> None:
        recorder = Recorder()
        outcome = run_sequence(make_inputs(), recorder.runner())
        self.assertEqual(
            recorder.calls, ["create_job", "job_state", "read_version", "sync_api"]
        )
        self.assertEqual(
            recorder.sync_arguments, ["apps:Deployment:mafest-app/mafest-api"]
        )
        self.assertTrue(outcome.synced)


if __name__ == "__main__":
    unittest.main()
