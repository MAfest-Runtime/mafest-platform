#!/bin/sh
# 검증이 끝난 테스트 자원을 단계별로 회수한다.
#
# 명령을 하나씩 붙여넣는 방식에는 "실패하면 멈춘다"는 의미가 없다. 앞 게이트가 중단
# 메시지를 내도 뒤의 delete는 그대로 실행된다. 그래서 단계 전체를 set -eu 스크립트 하나로
# 묶는다. 게이트 함수의 return 1 이 스크립트를 즉시 끝내므로 뒤 삭제가 실행되지 않는다.
#
# 이 규칙을 지켜야 위 보장이 성립한다.
#   - 게이트 함수는 반드시 평문으로 호출한다. `gate && delete` 나 `if gate` 처럼
#     조건 문맥에 넣으면 set -e 가 동작하지 않아 보호가 사라진다.
#   - 삭제는 전부 run_delete 를 통과시킨다. dry-run 분기가 한 곳뿐이어야
#     "--confirm 없이는 삭제 0건"을 검사로 증명할 수 있다.
#
# 절차와 기대값의 근거는 runbooks/test-resource-cleanup.md 에 있다.
# 회귀 검사는 scripts/test-cleanup-guards.sh 가 가짜 kubectl 로 수행한다.
set -eu

usage() {
  cat >&2 <<'USAGE'
사용법: sh scripts/cleanup-test-resources.sh <단계> [--confirm]

단계
  migration       persona-migrate Application 등록 해제와 완료된 Job 회수
  nfs             nfs-smoke-data PVC 와 연결된 PV 회수 (서버 디렉터리는 런북 D절)
  verify          남은 Application·서비스·저장소 상태 확인 (삭제 없음)

--confirm 이 없으면 dry-run 이다. 읽기 전용 게이트만 돌고 삭제는 출력만 한다.
USAGE
  exit 2
}

# ---- 인자 -------------------------------------------------------------------
STAGE=${1:-}
test -n "$STAGE" || usage
shift
CONFIRM=no
for arg in "$@"; do
  case "$arg" in
    --confirm) CONFIRM=yes ;;
    *) echo "알 수 없는 인자: $arg" >&2; usage ;;
  esac
done

# ---- 고정값 -----------------------------------------------------------------
# CP 에 등록된 context. execution-locations.md 에 따라 홈 운영은 CP 에서만 한다.
# 노트북 context(persona-home)로는 실행되지 않게 막는다.
CP_CONTEXT=${PERSONA_CP_CONTEXT:-kubernetes-admin@kubernetes}
K="kubectl --context=$CP_CONTEXT"

MIGRATE_APP=persona-migrate
MIGRATE_JOB=persona-migrate-0001-persona-minimal
APP_NS=persona-app
NFS_NS=persona-nfs-test
NFS_PVC=nfs-smoke-data
# migration Job 이 우리가 승인한 그 실행인지 확인하는 기대값.
WANT_MIGRATE_IMAGE=${PERSONA_MIGRATE_IMAGE:-ghcr.io/mafest-runtime/persona-minimal-api@sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6}

# PV 신원 기대값. 20Gi 운영 PV(persona-db·Prometheus)와 혼동하지 않기 위한 관문이다.
WANT_SC=nfs-shared
WANT_CAP=1Gi
WANT_RECLAIM=Retain
WANT_SERVER=192.168.50.205
WANT_SHARE=/srv/nfs/k8s
# 이번 정리는 "조건에 맞는 아무 PV"가 아니라 승인받은 대상 하나를 지우는 일회성 작업이다.
# 대상을 고정하지 않으면, 같은 이름의 PVC 가 재생성됐을 때 새 PV 를 지우면서
# 런북 D 절은 옛 서버 디렉터리를 지우는 불일치가 생긴다.
# 다음 정리에서는 승인된 새 값을 환경변수로 넘긴다.
WANT_PV=${PERSONA_CLEANUP_PV:-pvc-96341d34-df4e-4a1e-8d74-3b91ccf5be15}
WANT_SUBDIR=$WANT_PV

# ---- 공통 ------------------------------------------------------------------
require_tools() {
  for tool in kubectl mktemp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "중단: 필요한 도구가 없다: $tool" >&2; return 1; }
  done
}

assert_context() {
  cur=$($K config current-context 2>&1) \
    || { echo "중단: context 조회가 실패했다 — $cur" >&2; return 1; }
  test "$cur" = "$CP_CONTEXT" || {
    echo "중단: context 가 $CP_CONTEXT 가 아니다 [$cur]. 홈 운영은 CP 에서 실행한다" >&2
    return 1
  }
  echo "확인: context $CP_CONTEXT"
}

# namespace 존재를 먼저 본다. kubectl get --ignore-not-found 는 없는 namespace 에서도
# rc=0 과 빈 출력을 주므로, 이 검사가 없으면 namespace 오타를 "리소스 없음"으로 읽는다.
assert_ns_exists() {
  ns=$1
  if ! out=$($K get namespace "$ns" --ignore-not-found -o name 2>&1); then
    echo "중단: namespace $ns 조회가 실패했다 — $out" >&2; return 1
  fi
  test -n "$out" || { echo "중단: namespace $ns 가 없다" >&2; return 1; }
  echo "확인: namespace $ns 있음"
}

# 부재 판정에 문자열 검색을 쓰지 않는다. "not found" 를 찾는 방식은 자격증명 도구 오류
# (executable credential-helper not found) 까지 리소스 부재로 인정했다.
# 이름을 지정한 조회의 종료 코드와 빈 출력만 본다. 조회 실패는 실패다.
assert_absent() {            # assert_absent <설명> <kubectl 인자...>
  what=$1; shift
  if ! out=$($K "$@" --ignore-not-found -o name 2>&1); then
    echo "중단: $what 조회가 실패했다 — $out" >&2; return 1
  fi
  test -z "$out" || { echo "중단: $what 이(가) 아직 있다 — $out" >&2; return 1; }
  echo "확인: $what 없음"
}

assert_present() {           # assert_present <설명> <kubectl 인자...>
  what=$1; shift
  if ! out=$($K "$@" --ignore-not-found -o name 2>&1); then
    echo "중단: $what 조회가 실패했다 — $out" >&2; return 1
  fi
  test -n "$out" || { echo "중단: $what 이(가) 없다" >&2; return 1; }
  echo "확인: $what 있음 — $out"
}

# 과거 조회로 "연쇄 삭제 위험 없음"을 보장하지 않는다. 삭제 직전에 다시 본다.
assert_no_finalizer() {
  app=$1
  if ! fin=$($K -n argocd get application "$app" -o jsonpath='{.metadata.finalizers}' 2>&1); then
    echo "중단: $app finalizer 조회가 실패했다 — $fin" >&2; return 1
  fi
  test -z "$fin" || {
    echo "중단: $app 에 finalizer 가 있다 [$fin] — 삭제가 연쇄될 수 있다" >&2; return 1
  }
  echo "확인: $app finalizer 없음"
}

# 삭제는 모두 여기를 지난다. dry-run 분기가 한 곳뿐이라 --confirm 없이 삭제가 나가지 않는다.
run_delete() {
  if test "$CONFIRM" != yes; then
    echo "[dry-run] 실행 예정: kubectl $*"
    return 0
  fi
  echo "실행: kubectl $*"
  $K "$@"
}

# ---- 단계: migration --------------------------------------------------------
# Job 이 "있다"는 것만 보고 지우면, 같은 이름으로 migration 이 다시 돌고 있어도 끊는다.
# 2절의 과거 완료 기록은 "그때 적용됐다"는 증거일 뿐 "지금 돌고 있지 않다"는 증거가 아니다.
# 그래서 삭제 직전 상태를 직접 본다. 읽기 전용이라 dry-run 에서도 그대로 실행한다.
assert_job_complete() {
  job=$1
  # jsonpath 는 없는 조건·필드를 빈 문자열로 준다. 공백으로 구분하면 빈 필드가 사라져
  # 뒤 값이 앞자리로 밀린다(Failed 없는 정상 Job 의 이미지가 active 자리로 온다).
  # 그래서 | 로 구분하고 cut 으로 자리를 고정해 읽는다.
  if ! st=$($K -n "$APP_NS" get job "$job" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}|{.status.conditions[?(@.type=="Failed")].status}|{.status.active}|{.status.succeeded}|{.spec.template.spec.containers[0].image}' 2>&1); then
    echo "중단: Job $job 상태 조회가 실패했다 — $st" >&2; return 1
  fi
  complete=$(printf  '%s' "$st" | cut -d'|' -f1)
  failed=$(printf    '%s' "$st" | cut -d'|' -f2)
  active=$(printf    '%s' "$st" | cut -d'|' -f3)
  succeeded=$(printf '%s' "$st" | cut -d'|' -f4)
  image=$(printf     '%s' "$st" | cut -d'|' -f5)

  # Failed 를 먼저 본다. 실패한 Job 은 Complete 조건도 없으므로, 순서를 바꾸면
  # "Complete 가 아니다" 라는 덜 구체적인 이유만 나오고 실패 사실이 묻힌다.
  test "$failed" != True || {
    echo "중단: Job $job 이 Failed 다. 로그를 보관하고 원인을 먼저 본다" >&2; return 1; }
  test "$complete" = True || {
    echo "중단: Job $job 이 Complete 가 아니다 [conditions=$st]" >&2; return 1; }
  # 실행 중인 재시도를 끊지 않기 위한 핵심 검사다.
  case "${active:-0}" in
    ''|0) : ;;
    *) echo "중단: Job $job 에 실행 중인 Pod 가 $active 개 있다" >&2; return 1 ;;
  esac
  case "${succeeded:-0}" in
    ''|0) echo "중단: Job $job 의 succeeded 가 0 이다" >&2; return 1 ;;
  esac
  test "$image" = "$WANT_MIGRATE_IMAGE" || {
    echo "중단: Job $job 의 이미지가 기대값과 다르다" >&2
    echo "  기대: $WANT_MIGRATE_IMAGE" >&2
    echo "  실제: $image" >&2
    return 1
  }
  echo "확인: Job $job 완료 (succeeded=$succeeded, 활성 없음, 이미지 일치)"
}

stage_migration() {
  assert_ns_exists argocd
  assert_ns_exists "$APP_NS"
  assert_job_complete "$MIGRATE_JOB"
  assert_no_finalizer "$MIGRATE_APP"

  run_delete -n argocd delete application "$MIGRATE_APP" --wait=true --timeout=60s

  if test "$CONFIRM" = yes; then
    assert_absent "Application $MIGRATE_APP" -n argocd get application "$MIGRATE_APP"
    # Application 에 finalizer 가 없으므로 삭제는 비연쇄다. Job 이 같이 사라졌다면
    # 예상하지 못한 자동화가 있다는 뜻이므로 여기서 멈춘다.
    assert_present "Job $MIGRATE_JOB" -n "$APP_NS" get job "$MIGRATE_JOB"
  fi

  run_delete -n "$APP_NS" delete job "$MIGRATE_JOB" \
    --cascade=foreground --wait=true --timeout=120s

  if test "$CONFIRM" = yes; then
    assert_absent "Job $MIGRATE_JOB" -n "$APP_NS" get job "$MIGRATE_JOB"
  fi

  echo "--- 서비스 무영향 확인 ---"
  $K -n "$APP_NS" get pod
  $K -n "$APP_NS" get secret
  if test "$CONFIRM" = yes; then
    $K -n "$APP_NS" rollout status deploy/persona-gateway --timeout=60s
  fi
  echo "migration 단계 완료 (confirm=$CONFIRM)"
}

# ---- 단계: NFS --------------------------------------------------------------
# 참조 필드는 .spec.source.persistentVolumeName 이다. 객체 이름에 PV 이름이 들어간다는
# 보장이 없으므로 -o name 과 이름 검색으로는 참조를 놓친다.
# nfs.csi.k8s.io 는 attachRequired=false 라 보통 이 객체가 없지만, 안전 검사로 유지한다.
assert_no_volumeattachment() {
  pv=$1
  if ! va=$($K get volumeattachment -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.source.persistentVolumeName}{"\n"}{end}' 2>&1); then
    echo "중단: VolumeAttachment 조회가 실패했다 — $va" >&2; return 1
  fi
  # 두 번째 필드를 정확히 비교한다. 부분 일치에 기대지 않는다.
  hit=$(printf '%s\n' "$va" | awk -v pv="$pv" '$2 == pv {print $1}')
  test -z "$hit" || {
    echo "중단: $pv 를 참조하는 VolumeAttachment 가 있다 — $hit" >&2; return 1
  }
  echo "확인: $pv 를 참조하는 VolumeAttachment 없음"
}

# 삭제 전에 PVC 와 PV 의 신원을 대조한다. PV 이름을 사람이 적지 않고 PVC 에서 끌어온다.
assert_pv_identity() {
  pv=$1
  if ! got=$($K get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name} {.spec.capacity.storage} {.spec.persistentVolumeReclaimPolicy} {.spec.storageClassName} {.spec.csi.volumeAttributes.server} {.spec.csi.volumeAttributes.share} {.spec.csi.volumeAttributes.subDir}' 2>&1); then
    echo "중단: PV $pv 조회가 실패했다 — $got" >&2; return 1
  fi
  # subDir 기대값은 $pv(자기 자신)가 아니라 승인된 WANT_SUBDIR 이다. 자기 자신과 비교하면
  # 어떤 PV 를 넣어도 이 필드는 항상 일치해 검사가 되지 않는다.
  want="$NFS_NS/$NFS_PVC $WANT_CAP $WANT_RECLAIM $WANT_SC $WANT_SERVER $WANT_SHARE $WANT_SUBDIR"
  test "$got" = "$want" || {
    echo "중단: PV 신원이 기대값과 다르다" >&2
    echo "  기대: $want" >&2
    echo "  실제: $got" >&2
    return 1
  }
  echo "확인: PV $pv 신원 일치"
}

stage_nfs() {
  assert_ns_exists "$NFS_NS"
  assert_absent "namespace $NFS_NS 의 Pod" -n "$NFS_NS" get pod

  if ! pvname=$($K -n "$NFS_NS" get pvc "$NFS_PVC" -o jsonpath='{.spec.volumeName}' 2>&1); then
    echo "중단: PVC $NFS_PVC 조회가 실패했다 — $pvname" >&2; return 1
  fi
  test -n "$pvname" || { echo "중단: PVC $NFS_PVC 에 연결된 PV 가 없다" >&2; return 1; }
  # 승인된 대상과 같은지 본다. 같은 이름의 PVC 가 재생성돼 다른 PV 에 붙었다면 이번 정리
  # 범위가 아니다. 그대로 진행하면 새 PV 를 지우고 런북 D 절은 옛 디렉터리를 지운다.
  test "$pvname" = "$WANT_PV" || {
    echo "중단: PVC 가 승인된 PV 와 다른 PV 에 연결돼 있다" >&2
    echo "  승인: $WANT_PV" >&2
    echo "  현재: $pvname" >&2
    echo "  PVC 가 재생성된 것으로 보인다. 정리 대상을 다시 승인받고 PERSONA_CLEANUP_PV 로 넘긴다" >&2
    return 1
  }
  echo "확인: PVC $NFS_PVC → PV $pvname (승인된 대상)"

  assert_no_volumeattachment "$pvname"
  assert_pv_identity "$pvname"

  run_delete -n "$NFS_NS" delete pvc "$NFS_PVC" --wait=true --timeout=120s
  if test "$CONFIRM" = yes; then
    assert_absent "PVC $NFS_PVC" -n "$NFS_NS" get pvc "$NFS_PVC"
    if ! phase=$($K get pv "$pvname" -o jsonpath='{.status.phase}' 2>&1); then
      echo "중단: PV $pvname 상태 조회가 실패했다 — $phase" >&2; return 1
    fi
    test "$phase" = Released || {
      echo "중단: PV 가 Released 가 아니다 [$phase]" >&2; return 1
    }
    echo "확인: PV $pvname Released"
  fi

  run_delete delete pv "$pvname" --wait=true --timeout=120s
  if test "$CONFIRM" = yes; then
    assert_absent "PV $pvname" get pv "$pvname"
  fi

  echo "--- 남은 저장소 ---"
  $K get pv
  $K get sc
  echo "NFS 단계 완료 (confirm=$CONFIRM)"
  echo "서버 디렉터리는 NFS VM 에서 별도로 지운다. runbooks/test-resource-cleanup.md 3절 D 참조."
}

# ---- 단계: verify -----------------------------------------------------------
assert_no_leftovers() {
  if ! all=$($K get all -A -o name 2>&1); then
    echo "중단: 잔재 조회가 실패했다 — $all" >&2; return 1
  fi
  if printf '%s\n' "$all" | grep -E 'persona-migrate'; then
    echo "중단: 정리 대상 잔재가 남아 있다" >&2; return 1
  fi
  echo "확인: 잔재 없음"
}

stage_verify() {
  echo "--- Application ---"
  $K -n argocd get applications.argoproj.io \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
  # persona 앱·DB·NFS Application은 2026-10-07 폐기했다(chore/retire-persona). 정리 뒤 남는 것만 적는다.
  echo "  기대(persona 폐기 뒤): public-gateway / maintenance-page / persona-edge / monitoring-stack / 공용 Application"
  echo "  monitoring-stack 의 OutOfSync 는 이번 범위 밖의 기존 상태다"
  echo "--- 서비스 ---"
  $K -n "$APP_NS"     get pod -o wide
  $K -n persona-data  get pod,pvc -o wide
  $K -n monitoring    get pod
  echo "--- 저장소와 라우팅 ---"
  $K get pv
  $K get sc
  $K get ns
  $K get gateway,httproute -A
  assert_no_leftovers
  echo "verify 단계 완료"
}

# ---- 실행 ------------------------------------------------------------------
require_tools
assert_context
case "$STAGE" in
  migration)       stage_migration ;;
  nfs)             stage_nfs ;;
  verify)          stage_verify ;;
  *)               echo "알 수 없는 단계: $STAGE" >&2; usage ;;
esac
