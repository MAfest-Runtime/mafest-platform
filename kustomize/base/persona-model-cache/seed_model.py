"""모델 cache seed: 고정 revision을 내려받고 upstream metadata와 대조한 뒤에만 완료로 표시한다.

persona-vllm-model-seed Job이 vLLM image(huggingface_hub 포함) 안에서 실행한다. GPU를 쓰지 않는다.

흐름:
1. Hugging Face API에서 고정 revision의 metadata(`files_metadata=True`)를 읽는다. 돌려받은
   commit이 요청한 40자리 revision과 정확히 같아야 한다 — branch 이름이나 짧은 해시는 받지 않는다.
2. `snapshot_download`로 staging 디렉터리(`/models/.staging/<revision>`)에 받는다.
3. staging을 metadata와 대조한다. 명령이 0으로 끝난 것만으로는 완료가 아니다.
   - 파일 목록이 upstream과 정확히 같다(빠진 파일·남는 파일 모두 실패).
   - 파일마다 크기가 같다.
   - LFS 파일(가중치·tokenizer.json)은 sha256, 나머지는 git blob sha1이 같다.
   - 필수 파일(config·tokenizer)과 가중치가 있다. 가중치는 weight index가 있으면 index가 가리키는 shard가
     모두 있어야 하고, index가 없는 단일 파일 체크포인트(예: 공식 FP8)는 `model.safetensors`가 있어야 한다.
4. 통과하면 manifest와 완료 marker를 쓰고 최종 경로(`/models/<model id>/<revision>`)로 rename한다.
   같은 파일시스템 안의 rename이라 "절반만 받은 최종 경로"가 생기지 않는다.

이미 marker가 있는 최종 경로는 다시 받지 않고 같은 기준으로 재검증만 한다. 재검증이 실패하면
덮어쓰지 않고 실패한다 — 무엇이 망가졌는지 사람이 보고 정리한다(Retain PV).

종료 코드: 0 성공(새로 받음 또는 기존 cache 재검증 통과), 1 무결성·다운로드 실패, 2 설정 오류.
토큰·원문을 출력하지 않는다. 이 모델은 gated가 아니라 토큰을 쓰지 않는다.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

EXIT_OK = 0
EXIT_INTEGRITY = 1
EXIT_CONFIG = 2

FULL_REVISION = re.compile(r"^[0-9a-f]{40}$")
MARKER_NAME = ".persona-seed-complete.json"
MANIFEST_NAME = ".persona-seed-manifest.json"
# snapshot_download(local_dir=...)가 local_dir 안에 두는 다운로드 metadata. 모델 파일이 아니다.
HUB_LOCAL_METADATA_DIR = ".cache"
# vLLM이 모델을 올리는 데 반드시 필요한 파일. 하나라도 없으면 upstream 목록과 같더라도 실패로 본다
# — upstream repo 구성이 바뀌어 이 파일들이 사라졌다면 그대로 서빙하면 안 된다.
REQUIRED_FILES = (
    "config.json",
    "generation_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
)
# 가중치는 둘 중 하나로 판정한다. shard가 여럿인 체크포인트(BF16)는 index를 두고, 5GiB 안팎의 공식 FP8처럼
# 한 파일이면 index 없이 `model.safetensors` 하나다. index가 있으면 항상 그쪽 기준(shard 존재)이 우선한다.
WEIGHT_INDEX_NAME = "model.safetensors.index.json"
SINGLE_WEIGHT_NAME = "model.safetensors"
CHUNK_BYTES = 8 * 1024 * 1024


@dataclass(frozen=True)
class ExpectedFile:
    """upstream metadata가 말하는 파일 하나. LFS 파일은 sha256, 그 밖은 git blob sha1로 대조한다."""

    path: str
    size: int
    sha256: str | None
    blob_sha1: str | None


class SeedError(Exception):
    """완료로 표시하면 안 되는 상태."""


def expected_files_from_siblings(siblings: list[object]) -> dict[str, ExpectedFile]:
    """`model_info(files_metadata=True).siblings`를 대조 기준으로 바꾼다.

    크기나 해시가 비어 있는 항목이 있으면 대조할 수 없으므로 실패한다(추측하지 않는다).
    """
    expected: dict[str, ExpectedFile] = {}
    for sibling in siblings:
        path = getattr(sibling, "rfilename")
        size = getattr(sibling, "size", None)
        lfs = getattr(sibling, "lfs", None)
        blob_id = getattr(sibling, "blob_id", None)
        lfs_sha256 = getattr(lfs, "sha256", None) if lfs is not None else None
        if size is None:
            raise SeedError(f"upstream metadata에 크기가 없다: {path}")
        if lfs is not None and not lfs_sha256:
            raise SeedError(f"LFS 파일인데 sha256이 없다: {path}")
        if lfs is None and not blob_id:
            raise SeedError(f"일반 파일인데 blob id가 없다: {path}")
        expected[path] = ExpectedFile(path, int(size), lfs_sha256, None if lfs is not None else blob_id)
    return expected


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_blob_sha1(path: Path) -> str:
    """git이 파일 내용에 매기는 blob id(`sha1("blob <size>\\0" + 내용)`)."""
    digest = hashlib.sha1()
    digest.update(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def local_files(root: Path) -> set[str]:
    """비교 대상 파일 목록. hub의 다운로드 metadata와 이 스크립트의 marker·manifest는 뺀다."""
    files = set()
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if relative.split("/", 1)[0] == HUB_LOCAL_METADATA_DIR or relative in {MARKER_NAME, MANIFEST_NAME}:
            continue
        files.add(relative)
    return files


def verify_directory(root: Path, expected: dict[str, ExpectedFile]) -> list[str]:
    """root가 upstream과 같은지 본다. 문제 목록을 돌려준다(비어 있으면 통과)."""
    problems: list[str] = []
    missing_required = [name for name in REQUIRED_FILES if name not in expected]
    if missing_required:
        problems.append(f"upstream에 필수 파일이 없다: {missing_required}")
    if WEIGHT_INDEX_NAME not in expected and SINGLE_WEIGHT_NAME not in expected:
        problems.append(f"upstream에 가중치가 없다: {WEIGHT_INDEX_NAME} 또는 {SINGLE_WEIGHT_NAME}")

    present = local_files(root)
    for name in sorted(set(expected) - present):
        problems.append(f"파일이 없다: {name}")
    for name in sorted(present - set(expected)):
        problems.append(f"upstream에 없는 파일이 있다: {name}")

    for name in sorted(set(expected) & present):
        spec = expected[name]
        path = root / name
        size = path.stat().st_size
        if size != spec.size:
            problems.append(f"크기가 다르다: {name} {size} != {spec.size}")
            continue
        if spec.sha256 is not None and sha256_file(path) != spec.sha256:
            problems.append(f"sha256이 다르다: {name}")
        if spec.blob_sha1 is not None and git_blob_sha1(path) != spec.blob_sha1:
            problems.append(f"git blob sha1이 다르다: {name}")

    index_path = root / WEIGHT_INDEX_NAME
    if index_path.is_file():
        try:
            shards = set(json.loads(index_path.read_text())["weight_map"].values())
        except (ValueError, KeyError, TypeError) as error:
            problems.append(f"weight index를 읽지 못했다: {error}")
        else:
            for shard in sorted(shards - present):
                problems.append(f"weight index가 가리키는 shard가 없다: {shard}")
    return problems


def write_manifest(root: Path, model_id: str, revision: str, expected: dict[str, ExpectedFile]) -> None:
    """무엇을 대조했는지 cache 안에 남긴다. vLLM 배포 전 사람이 읽는 증거다."""
    manifest = {
        "model_id": model_id,
        "revision": revision,
        "files": [
            {"path": spec.path, "size": spec.size, "sha256": spec.sha256, "git_blob_sha1": spec.blob_sha1}
            for spec in sorted(expected.values(), key=lambda item: item.path)
        ],
    }
    (root / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2, sort_keys=True))
    marker = {"model_id": model_id, "revision": revision, "files": len(expected),
              "bytes": sum(spec.size for spec in expected.values())}
    (root / MARKER_NAME).write_text(json.dumps(marker, sort_keys=True))


def read_config() -> tuple[str, str, Path]:
    model_id = os.environ.get("MODEL_ID", "")
    revision = os.environ.get("MODEL_REVISION", "")
    target = os.environ.get("TARGET_DIR", "")
    if not model_id or "/" not in model_id:
        raise SeedError("MODEL_ID는 '<org>/<name>' 형식이어야 한다")
    if not FULL_REVISION.match(revision):
        raise SeedError("MODEL_REVISION은 40자리 commit hash여야 한다(branch·tag·짧은 해시는 받지 않는다)")
    if not target.startswith("/"):
        raise SeedError("TARGET_DIR은 절대 경로여야 한다")
    return model_id, revision, Path(target)


def seed(model_id: str, revision: str, target: Path, api: object, download: object) -> dict[str, object]:
    """api·download를 인자로 받아 테스트에서 가짜로 바꿀 수 있게 한다."""
    info = api.model_info(model_id, revision=revision, files_metadata=True)  # type: ignore[attr-defined]
    if getattr(info, "sha", None) != revision:
        raise SeedError(f"upstream이 돌려준 commit {getattr(info, 'sha', None)}이 요청 revision과 다르다")
    expected = expected_files_from_siblings(list(getattr(info, "siblings", None) or []))

    final = target / model_id / revision
    if (final / MARKER_NAME).is_file():
        problems = verify_directory(final, expected)
        if problems:
            raise SeedError(f"기존 cache 재검증 실패(덮어쓰지 않는다): {problems}")
        return {"result": "already_seeded", "path": str(final), "files": len(expected)}
    if final.exists():
        raise SeedError(f"완료 marker 없이 최종 경로가 있다 — 사람이 확인 후 정리한다: {final}")

    staging = target / ".staging" / revision
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    download(repo_id=model_id, revision=revision, local_dir=str(staging))  # type: ignore[operator]
    shutil.rmtree(staging / HUB_LOCAL_METADATA_DIR, ignore_errors=True)

    problems = verify_directory(staging, expected)
    if problems:
        raise SeedError(f"다운로드 결과가 upstream metadata와 다르다: {problems}")
    write_manifest(staging, model_id, revision, expected)
    final.parent.mkdir(parents=True, exist_ok=True)
    staging.rename(final)
    return {"result": "seeded", "path": str(final), "files": len(expected),
            "bytes": sum(spec.size for spec in expected.values())}


def main() -> int:
    try:
        model_id, revision, target = read_config()
    except SeedError as error:
        print(json.dumps({"result": "config_error", "error": str(error)}, ensure_ascii=False))
        return EXIT_CONFIG
    try:
        from huggingface_hub import HfApi, snapshot_download

        report = seed(model_id, revision, target, HfApi(), snapshot_download)
    except SeedError as error:
        print(json.dumps({"result": "integrity_error", "error": str(error)}, ensure_ascii=False))
        return EXIT_INTEGRITY
    except Exception as error:  # 네트워크·권한·용량 등. 원인 종류만 남기고 재시도하지 않는다.
        print(json.dumps({"result": "download_error", "error": f"{type(error).__name__}: {error}"},
                         ensure_ascii=False))
        return EXIT_INTEGRITY
    print(json.dumps(report, ensure_ascii=False))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
