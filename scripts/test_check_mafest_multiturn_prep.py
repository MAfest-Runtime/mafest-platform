"""check_mafest_multiturn_prep.py 가 핵심 위반을 실제로 잡는지 변형 사본으로 시험한다.

원본 저장소는 수정하지 않는다. 필요한 디렉터리만 임시 폴더에 복사해 한 곳씩 망가뜨린다.
실행: python3 -I scripts/test_check_mafest_multiturn_prep.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CHECKER = REPO / "scripts" / "check_mafest_multiturn_prep.py"
COPIED = ("kustomize", "deploy", "argocd", "db")


class CheckerDetectsViolationsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in COPIED:
            shutil.copytree(REPO / name, self.root / name)
        self.drafts = self.root / "deploy/mafest-multiturn/drafts"
        # 검사기가 읽는 스크립트 위치도 사본에 맞춘다.
        (self.root / "scripts").mkdir()
        shutil.copy(REPO / "scripts/mafest_sync_db_secret.py", self.root / "scripts")
        shutil.copy(CHECKER, self.root / "scripts")
        (self.root / "scripts/fault").mkdir()
        shutil.copy(REPO / "scripts/fault/mafest_fault.py", self.root / "scripts/fault")

    def run_checker(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(CHECKER), *args],
            env={**os.environ, "MAFEST_PREP_REPO": str(self.root)},
            capture_output=True,
            text=True,
            check=False,
        )

    def edit(self, name: str, old: str, new: str) -> None:
        path = self.drafts / name
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new), encoding="utf-8")

    def test_unmodified_copy_passes_but_reports_incomplete(self) -> None:
        result = self.run_checker()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("준비 미완료", result.stdout)

    def test_require_complete_fails_while_placeholders_remain(self) -> None:
        self.assertEqual(self.run_checker("--require-complete").returncode, 1)

    def test_active_cleanup_cronjob_is_rejected(self) -> None:
        self.edit(
            "session-cleanup-cronjob.yaml.draft", "suspend: true", "suspend: false"
        )
        self.assertEqual(self.run_checker().returncode, 1)

    def test_workload_without_matching_ingress_policy_is_rejected(self) -> None:
        self.edit(
            "network-policy.yaml.draft",
            "app.kubernetes.io/name: mafest-session-cleanup\n      ports",
            "app.kubernetes.io/name: other\n      ports",
        )
        self.assertEqual(self.run_checker().returncode, 1)

    def test_reusing_existing_allowed_label_is_rejected(self) -> None:
        text = (self.drafts / "migration-job.yaml.draft").read_text(encoding="utf-8")
        (self.drafts / "migration-job.yaml.draft").write_text(
            text.replace(
                "app.kubernetes.io/name: mafest-session-migrate",
                "app.kubernetes.io/name: mafest-loader",
            ),
            encoding="utf-8",
        )
        self.assertEqual(self.run_checker().returncode, 1)

    def test_broad_grant_in_template_is_rejected(self) -> None:
        self.edit(
            "session-role-grants.sql.tmpl",
            "GRANT USAGE ON SCHEMA",
            "GRANT ALL PRIVILEGES ON SCHEMA",
        )
        self.assertEqual(self.run_checker().returncode, 1)

    def test_password_shaped_text_is_rejected(self) -> None:
        self.edit(
            "migration-job.yaml.draft",
            "backoffLimit: 0",
            "backoffLimit: 0\n  # postgresql://user:hunter2@host/db",
        )
        self.assertEqual(self.run_checker().returncode, 1)

    def test_delete_with_limit_in_cleanup_draft_is_rejected(self) -> None:
        self.edit(
            "session-cleanup-cronjob.yaml.draft",
            "              command:\n                - __APP_CLEANUP_CLI__",
            "              command:\n                - psql -c 'DELETE FROM t LIMIT 10'",
        )
        self.assertEqual(self.run_checker().returncode, 1)

    def test_draft_wired_into_kustomization_is_rejected(self) -> None:
        kustomization = self.root / "kustomize/base/mafest-app/kustomization.yaml"
        kustomization.write_text(
            kustomization.read_text(encoding="utf-8")
            + "\n# ../../../deploy/mafest-multiturn\n",
            encoding="utf-8",
        )
        self.assertEqual(self.run_checker().returncode, 1)

    def test_kubectl_call_bypassing_context_gateway_is_rejected(self) -> None:
        tool = self.root / "scripts/fault/mafest_fault.py"
        tool.write_text(
            tool.read_text(encoding="utf-8")
            + '\n\ndef leaked() -> None:\n    subprocess.run(["kubectl", "get", "pods"], check=False)\n',
            encoding="utf-8",
        )
        self.assertEqual(self.run_checker().returncode, 1)


if __name__ == "__main__":
    unittest.main()
