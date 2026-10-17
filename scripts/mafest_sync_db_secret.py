"""mafest-data의 DB 비밀번호 Secret 키를 mafest-app Secret으로 옮기는 도구.

다른 namespace의 Secret은 Pod가 직접 참조할 수 없어서 사람이 값을 복제해야 한다.
이 도구는 그 복제를 값 노출 없이 하도록 만든다.

- 기본 실행은 계획만 출력하고 kubectl을 호출하지 않는다.
- 값은 디코드하지 않는다. 원본의 base64 문자열을 그대로 patch에 실어 stdin으로 넘긴다.
  (명령줄 인자에 값을 넣으면 `ps`에 보이므로 stdin을 쓴다.)
- 허용한 source/target/key 조합이 아니면 거부한다. 임의의 Secret을 복사하는 도구가 되지 않게 한다.
- kubectl의 stderr는 그대로 보여 주지 않는다. 오류 문구에 값이 섞일 가능성을 없애기 위해 고정 문구만 출력한다.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

# 허용 조합은 한 가지뿐이다. 늘리려면 코드를 고치고 리뷰를 받는다.
SOURCE_NAMESPACE = "mafest-data"
SOURCE_SECRET = "mafest-db-runtime"
SOURCE_KEY = "password"
TARGET_NAMESPACE = "mafest-app"
TARGET_SECRET = "mafest-api-db"
TARGET_KEY = "PGPASSWORD"
APPLY_CONFIRMATION = TARGET_SECRET
KUBECTL_TIMEOUT_S = 20


class SyncError(Exception):
    """비밀값을 담지 않는 고정 문구만 가진 오류."""


def kubectl_binary() -> str:
    # 시험에서 가짜 kubectl을 쓰기 위해 환경변수로 바꿀 수 있다.
    return os.environ.get("MAFEST_KUBECTL", "kubectl")


def run_kubectl(context: str, args: list[str], stdin_text: str | None = None) -> str:
    """kubectl을 실행하고 stdout을 돌려준다. stderr는 버린다.

    모든 호출이 이 함수를 지나며 `--context <승인값>`이 항상 붙는다. 현재 context가 바뀌어 있어도
    다른 클러스터의 Secret을 읽거나 쓰지 않게 하기 위해서다.
    """
    try:
        result = subprocess.run(
            [kubectl_binary(), "--context", context, *args],
            input=stdin_text,
            # 입력이 없는 호출이 부모 터미널의 stdin을 물려받아 멈추지 않도록 막는다.
            stdin=None if stdin_text is not None else subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=KUBECTL_TIMEOUT_S,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SyncError(f"kubectl 실행 실패({type(error).__name__})") from None
    if result.returncode != 0:
        raise SyncError(f"kubectl 비정상 종료(코드 {result.returncode})")
    return result.stdout


def read_source_value_b64(context: str) -> str:
    """원본 Secret에서 허용된 키의 base64 값만 꺼낸다. 값은 반환만 하고 출력하지 않는다."""
    raw = run_kubectl(
        context,
        ["get", "secret", SOURCE_SECRET, "-n", SOURCE_NAMESPACE, "-o", "json"],
    )
    try:
        data = json.loads(raw).get("data", {})
    except json.JSONDecodeError:
        raise SyncError("원본 Secret 응답을 해석하지 못했다") from None
    value = data.get(SOURCE_KEY)
    if not value:
        raise SyncError(f"원본 Secret에 {SOURCE_KEY} 키가 없다")
    return value


def patch_target(context: str, value_b64: str) -> None:
    """대상 Secret에 키 하나만 추가한다. 다른 키(PGURL 등)는 건드리지 않는다."""
    patch = json.dumps({"data": {TARGET_KEY: value_b64}})
    run_kubectl(
        context,
        [
            "patch",
            "secret",
            TARGET_SECRET,
            "-n",
            TARGET_NAMESPACE,
            "--type=merge",
            "--patch-file=/dev/stdin",
        ],
        stdin_text=patch,
    )


def print_plan(context: str | None) -> None:
    print("계획(클러스터 접속 없음):")
    print(f"  context: {context or '(미지정 — --apply 에는 --expect-context 필요)'}")
    print(f"  원본  : {SOURCE_NAMESPACE}/{SOURCE_SECRET} 키 {SOURCE_KEY}")
    print(
        f"  대상  : {TARGET_NAMESPACE}/{TARGET_SECRET} 키 {TARGET_KEY} 추가(기존 키 유지)"
    )
    print("  값은 출력하거나 파일로 남기지 않는다.")
    print(
        f"  실제로 옮기려면: --apply --confirm {APPLY_CONFIRMATION} --expect-context <승인한 context>"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--apply", action="store_true", help="실제로 대상 Secret에 키를 추가한다"
    )
    parser.add_argument(
        "--confirm", default="", help="대상 Secret 이름을 다시 입력해 확인한다"
    )
    parser.add_argument(
        "--expect-context",
        default="",
        help="승인한 kubectl context. 모든 kubectl 호출에 --context 로 붙는다",
    )
    args = parser.parse_args(argv)

    if not args.apply:
        print_plan(args.expect_context or None)
        return 0
    if not args.expect_context:
        print("--apply 에는 --expect-context 가 필요하다.", file=sys.stderr)
        return 2
    if args.confirm != APPLY_CONFIRMATION:
        print(
            "확인 문구가 맞지 않아 중단한다(--confirm 에 대상 Secret 이름 필요).",
            file=sys.stderr,
        )
        return 2
    try:
        patch_target(args.expect_context, read_source_value_b64(args.expect_context))
    except SyncError as error:
        print(f"실패: {error}", file=sys.stderr)
        return 1
    print(
        f"완료: {TARGET_NAMESPACE}/{TARGET_SECRET} 에 {TARGET_KEY} 키를 추가했다(값은 출력하지 않음)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
