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
  mock-sse        persona-mock-sse Application·워크로드·namespace 회수
  mock-sse-finish mock-sse 가 namespace 삭제 직전에 멈췄을 때 마무리만 다시 수행
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
MOCK_APP=persona-mock-sse
MOCK_NS=persona-mock-sse
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

# ---- 단계: mock SSE ---------------------------------------------------------
# pull Secret 검사는 삭제 전과 삭제 후가 다르다.
#
# 삭제 전에는 mock SSE Deployment 가 아직 살아 있으므로 그 Pod 가 Secret 을 참조하는 것이
# 정상이다. 여기에 "참조가 전혀 없어야 한다"를 적용하면 정상 클러스터에서 dry-run 이 중단된다.
# 그래서 삭제 전에는 "참조가 모두 정리 대상인가"만 보고, 완전한 부재는 실제로 지운 뒤에 본다.

# 참조하는 Pod 이름을 한 줄씩 뽑는다. Secret 은 namespace 를 넘지 않으므로 이 namespace 만 본다.
pull_secret_consumers() {
  $K -n "$MOCK_NS" get pod \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.imagePullSecrets[*]}{.name}{","}{end}{"\n"}{end}'
}

# ownerReferences[0] 를 kind|name|uid|controller 네 값으로 읽는다.
# 이름만 맞춰서는 안 된다. 같은 이름의 다른 객체를 가리키는 참조를 uid 로 걸러낸다.
owner_ref_of() {          # owner_ref_of <kind> <name>
  $K -n "$MOCK_NS" get "$1" "$2" -o jsonpath='{.metadata.ownerReferences[0].kind}|{.metadata.ownerReferences[0].name}|{.metadata.ownerReferences[0].uid}|{.metadata.ownerReferences[0].controller}' 2>&1
}

uid_of() {                # uid_of <kind> <name> — 없으면 빈 문자열
  $K -n "$MOCK_NS" get "$1" "$2" --ignore-not-found -o jsonpath='{.metadata.uid}' 2>&1
}

# owner 참조가 기대한 대상인지 본다. want_ctrl=yes 면 controller=true 까지 요구한다.
# Cilium 은 ciliumendpoint 의 controller 를 세우지 않으므로 그 kind 에는 요구하지 않는다.
owner_matches() {         # owner_matches <ref> <want_kind> <want_name> <want_uid> <want_ctrl>
  ref=$1; wk=$2; wn=$3; wu=$4; wc=$5
  k=$(printf '%s' "$ref" | cut -d'|' -f1)
  n=$(printf '%s' "$ref" | cut -d'|' -f2)
  u=$(printf '%s' "$ref" | cut -d'|' -f3)
  c=$(printf '%s' "$ref" | cut -d'|' -f4)
  test "$k" = "$wk" || return 1
  test "$n" = "$wn" || return 1
  test -n "$wu" && test "$u" = "$wu" || return 1
  test "$wc" != yes || test "$c" = true || return 1
  return 0
}

# ServiceAccount 에 pull Secret 이 붙어 있으면 우리가 모르는 배선이 있다는 신호다.
# namespace 를 지우면 사라지지만 그 전에 사람이 확인해야 한다.
# Pod 소유 확인은 여기가 아니라 인벤토리 게이트가 namespace 의 모든 Pod 에 대해 수행한다 —
# pull Secret 을 쓰지 않는 Pod 도 namespace 삭제에 함께 휩쓸리기 때문이다.
assert_sa_has_no_pull_secret() {
  if ! sas=$($K -n "$MOCK_NS" get sa -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .imagePullSecrets[*]}{.name}{","}{end}{"\n"}{end}' 2>&1); then
    echo "중단: ServiceAccount 조회가 실패했다 — $sas" >&2; return 1
  fi
  if printf '%s\n' "$sas" | grep -q "$MOCK_APP-ghcr"; then
    echo "중단: ServiceAccount 가 pull Secret 을 참조한다 — $sas" >&2; return 1
  fi
  echo "확인: ServiceAccount 에 pull Secret 참조 없음"
}

# namespace 자원을 전수 열거한다. 조회 실패를 빈 목록으로 읽지 않는다.
#
# stdout 과 stderr 를 분리해서 받는다($STDERR_FILE). 합쳐서 받으면(2>&1) rc=0 인 조회의
# stderr 경고까지 인벤토리 목록에 섞여 들어간다. 이 클러스터(서버 1.36 대)는 Endpoints
# 조회마다 "Warning: v1 Endpoints is deprecated ..." 를 stderr 로 찍는데, 그 문구가
# for 루프의 word-split 에서 공백 단위로 쪼개져 자원 이름처럼 취급되면서 실제로는
# 항상 승인 실패로 이어졌다(직접 재현해 확인함). 경고는 버리지 않고 별도로 남긴다.
ns_inventory() {          # ns_inventory <ns> — 성공 시 "kind/name" 목록을 출력
  ns=$1
  if ! kinds=$($K api-resources --verbs=list --namespaced -o name 2>"$STDERR_FILE"); then
    echo "중단: api-resources 조회가 실패했다 — $(cat "$STDERR_FILE")" >&2; return 1
  fi
  warn=$(cat "$STDERR_FILE")
  test -z "$warn" || echo "경고: api-resources 조회 stderr — $warn" >&2
  test -n "$kinds" || { echo "중단: api-resources 결과가 비어 있다" >&2; return 1; }
  for kind in $kinds; do
    if ! got=$($K -n "$ns" get "$kind" --ignore-not-found -o name 2>"$STDERR_FILE"); then
      echo "중단: $ns 의 $kind 조회가 실패했다 — $(cat "$STDERR_FILE")" >&2; return 1
    fi
    warn=$(cat "$STDERR_FILE")
    test -z "$warn" || echo "경고: $ns 의 $kind 조회 stderr — $warn" >&2
    test -z "$got" || printf '%s\n' "$got"
  done
}

# Event 는 다른 객체에서 일어난 일을 설명하는 감사 기록이다. 그 자체로는 데이터를 갖지
# 않으므로, 실제 리소스 승인((a)(b)(c))만큼 엄격하게 다루지 않아도 손실 위험이 없다 —
# 잘못 허용해도 최악의 경우 무해한 감사 기록 하나가 namespace 삭제에 함께 쓸려갈 뿐,
# 실제 자원이 오삭제되는 것은 아니다. 참조 필드(누구에 대한 기록인지)가 우리가 관리하는
# kind·이름과 관련될 때만 허용한다. Pod·ReplicaSet 은 Deployment 가 매번 다른 접미사로
# 이름을 짓고, 이 시점엔 대상이 이미 지워진 뒤라 uid 로 대조할 살아 있는 객체가 없다.
# 그래서 이 판정에서만 예외적으로 접두사를 쓴다 — 3cf6a32 에서 없앤 자원 승인용 접두사
# 허용과는 위험 성격이 다르다.
event_is_managed() {          # event_is_managed <참조 kind> <참조 name>
  iokind=$1; ioname=$2
  case "$iokind" in
    Deployment|Service|Secret|Gateway|HTTPRoute) test "$ioname" = "$MOCK_APP" ;;
    Pod|ReplicaSet)
      case "$ioname" in
        "$MOCK_APP"|"$MOCK_APP"-*) return 0 ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# ns_inventory 가 event/ 나 event.events.k8s.io/ 항목을 내놓으면 참조 필드를 조회해
# event_is_managed 로 판정한다. events 와 events.events.k8s.io 는 api-resources 에 둘 다
# 나열되고 같은 저장소를 공유하므로, 같은 Event 가 두 kind 문자열로 중복 열거될 수 있다.
# 다만 필드명은 API 그룹마다 다르다 — core v1 은 involvedObject, events.k8s.io/v1 은
# regarding 이다(kubectl explain events --api-version=v1 과
# --api-version=events.k8s.io/v1 로 직접 확인함). 같은 Event 를 가리켜도 응답 스키마
# 자체가 다르므로 kind 에 맞는 필드로 읽어야 판정이 같게 나온다 — 하나로만 조회하면
# events.k8s.io 쪽은 필드가 없어 빈 값만 나오고 정상 Event 도 미승인으로 잡힌다.
# 반환값은 0=승인, 1=미승인, 2=조회 실패로 나눠, 조회 실패는 호출부가 즉시 전체 단계를
# 중단시키게 한다.
classify_event() {            # classify_event <ns> <kind> <name>
  ns=$1; kind=$2; name=$3
  case "$kind" in
    event)               field='{.involvedObject.kind}|{.involvedObject.name}' ;;
    event.events.k8s.io) field='{.regarding.kind}|{.regarding.name}' ;;
    *) echo "중단: $kind 는 처리할 수 없는 Event kind 다" >&2; return 2 ;;
  esac
  if ! io=$($K -n "$ns" get "$kind" "$name" -o jsonpath="$field" 2>"$STDERR_FILE"); then
    echo "중단: $kind/$name 의 참조 필드 조회가 실패했다 — $(cat "$STDERR_FILE")" >&2; return 2
  fi
  warn=$(cat "$STDERR_FILE")
  test -z "$warn" || echo "경고: $kind/$name 참조 필드 조회 stderr — $warn" >&2
  iokind=$(printf '%s' "$io" | cut -d'|' -f1)
  ioname=$(printf '%s' "$io" | cut -d'|' -f2)
  event_is_managed "$iokind" "$ioname"
}

# namespace 전체 자원을 승인 조건과 대조한다.
#
# "pull Secret 소비자 없음" 은 namespace 삭제의 근거가 되지 못한다. delete namespace 는 그 안의
# 모든 것을 가져간다. 그리고 이름 접두사도 근거가 되지 못한다 — secret/persona-mock-sse-backup
# 처럼 같은 접두사를 쓴 무관한 자원이 승인돼 버린다. 그래서 kind 를 무시하지 않고,
# 파생 자원은 ownerReferences 를 실제로 확인한다.
assert_ns_inventory_approved() {
  ns=$1
  found=$(ns_inventory "$ns") || return 1

  # 소유 대조에 쓸 살아 있는 uid 를 먼저 읽는다. 없으면 빈 값이고, 그때는 그 kind 의
  # 파생 자원이 승인되지 않는다(소유를 증명할 대상이 없다).
  deploy_uid=$(uid_of deployment "$MOCK_APP") || { echo "중단: Deployment uid 조회 실패 — $deploy_uid" >&2; return 1; }
  svc_uid=$(uid_of service "$MOCK_APP")       || { echo "중단: Service uid 조회 실패 — $svc_uid" >&2; return 1; }

  approved_pods=""
  unexpected=""
  for item in $(printf '%s\n' "$found" | sort -u); do
    kind=${item%%/*}
    name=${item#*/}
    case "$item" in
      # (a) kind 와 이름의 정확한 조합. 접두사 허용은 쓰지 않는다.
      configmap/kube-root-ca.crt) continue ;;
      serviceaccount/default) continue ;;
      "secret/$MOCK_APP-ghcr") continue ;;
      "deployment.apps/$MOCK_APP") continue ;;
      "service/$MOCK_APP") continue ;;
      "endpoints/$MOCK_APP") continue ;;   # (c) 같은 이름의 Service 가 위에서 승인됐다
      "gateway.gateway.networking.k8s.io/$MOCK_APP") continue ;;
      "httproute.gateway.networking.k8s.io/$MOCK_APP") continue ;;
    esac

    # (b) 소유를 실제로 확인하는 파생 kind. 허용 kind 를 제한한다.
    case "$kind" in
      replicaset.apps)
        ref=$(owner_ref_of replicaset "$name") || { echo "중단: $item 소유 조회 실패 — $ref" >&2; return 1; }
        if owner_matches "$ref" Deployment "$MOCK_APP" "$deploy_uid" yes; then continue; fi
        ;;
      pod)
        ref=$(owner_ref_of pod "$name") || { echo "중단: $item 소유 조회 실패 — $ref" >&2; return 1; }
        rs=$(printf '%s' "$ref" | cut -d'|' -f2)
        rs_uid=$(uid_of replicaset "$rs") || { echo "중단: ReplicaSet uid 조회 실패 — $rs_uid" >&2; return 1; }
        if owner_matches "$ref" ReplicaSet "$rs" "$rs_uid" yes; then
          rsref=$(owner_ref_of replicaset "$rs") || { echo "중단: $rs 소유 조회 실패 — $rsref" >&2; return 1; }
          if owner_matches "$rsref" Deployment "$MOCK_APP" "$deploy_uid" yes; then
            approved_pods="$approved_pods $name"
            continue
          fi
        fi
        ;;
      endpointslice.discovery.k8s.io)
        ref=$(owner_ref_of endpointslice "$name") || { echo "중단: $item 소유 조회 실패 — $ref" >&2; return 1; }
        if owner_matches "$ref" Service "$MOCK_APP" "$svc_uid" yes; then continue; fi
        ;;
      ciliumendpoint.cilium.io)
        # Cilium 은 controller 를 세우지 않으므로 요구하지 않는다. uid 는 대조한다.
        ref=$(owner_ref_of ciliumendpoint "$name") || { echo "중단: $item 소유 조회 실패 — $ref" >&2; return 1; }
        pod_uid=$(uid_of pod "$name") || { echo "중단: Pod uid 조회 실패 — $pod_uid" >&2; return 1; }
        if owner_matches "$ref" Pod "$name" "$pod_uid" no; then continue; fi
        ;;
      event|event.events.k8s.io)
        # classify_event 를 단독 명령으로 부르면 set -e 가 nonzero 반환에서 곧바로
        # 스크립트를 끝내 event_rc=$? 조차 실행되지 못한다. AND-OR 목록으로 감싸
        # 이 명령의 실패가 즉시 종료를 유발하지 않게 한다.
        classify_event "$ns" "$kind" "$name" && event_rc=0 || event_rc=$?
        test "$event_rc" -eq 2 && return 1
        test "$event_rc" -eq 0 && continue
        ;;
    esac
    unexpected="$unexpected  $item
"
  done

  # (c) 소유를 증명할 수 없는 kind 는 이름 연결로 승인한다. 소유 증명이 아니다 —
  # podmetrics 는 ownerReferences 가 없는 가상 객체이고 Pod 와 이름만 같다.
  # 위에서 소유가 확인된 Pod 이름과 정확히 같을 때만 통과시킨다.
  remaining=""
  for item in $unexpected; do
    case "$item" in
      podmetrics.metrics.k8s.io/*)
        pmname=${item#*/}
        for ap in $approved_pods; do
          test "$ap" = "$pmname" && { pmname=""; break; }
        done
        test -z "$pmname" && continue
        ;;
    esac
    remaining="$remaining  $item
"
  done

  test -z "$remaining" || {
    echo "중단: $ns 에 승인 조건을 만족하지 않는 자원이 있다. namespace 를 지우면 함께 사라진다" >&2
    printf '%s' "$remaining" >&2
    echo "  보존해야 할 자원이면 먼저 옮기고, 지워도 되면 승인 조건을 갱신한다" >&2
    return 1
  }
  echo "확인: $ns 자원이 모두 승인 조건을 만족한다"
}

# namespace 삭제 직전 검사. 인벤토리 게이트와 다른, 더 좁은 목록을 쓴다.
# 이 시점에는 앞 단계가 모두 지워졌으므로 쿠버네티스가 자동으로 만드는 기본 자원 둘과,
# 정리 대상과 연관이 확인된 Event(classify_event) 만 남아야 한다. Pod 종료 과정에서
# 남는 Killing 같은 Event 를 무조건 막으면 정상 종료도 항상 여기서 멈추기 때문이다.
# 삭제 후 조건이므로 dry-run 에서는 부르지 않는다.
assert_ns_residue_only_defaults() {
  ns=$1
  found=$(ns_inventory "$ns") || return 1
  leftovers=""
  for item in $(printf '%s\n' "$found" | sort -u); do
    kind=${item%%/*}
    name=${item#*/}
    case "$item" in
      configmap/kube-root-ca.crt|serviceaccount/default) continue ;;
    esac
    case "$kind" in
      event|event.events.k8s.io)
        # classify_event 를 단독 명령으로 부르면 set -e 가 nonzero 반환에서 곧바로
        # 스크립트를 끝내 event_rc=$? 조차 실행되지 못한다. AND-OR 목록으로 감싸
        # 이 명령의 실패가 즉시 종료를 유발하지 않게 한다.
        classify_event "$ns" "$kind" "$name" && event_rc=0 || event_rc=$?
        test "$event_rc" -eq 2 && return 1
        test "$event_rc" -eq 0 && continue
        ;;
    esac
    leftovers="$leftovers  $item
"
  done
  test -z "$leftovers" || {
    echo "중단: $ns 에 기본 자원 외의 것이 남아 있어 namespace 를 지우지 않는다" >&2
    printf '%s' "$leftovers" >&2
    echo "  앞 삭제가 아직 정착되지 않았으면 sh scripts/cleanup-test-resources.sh mock-sse-finish --confirm 으로 마무리한다" >&2
    echo "  mock-sse 를 처음부터 다시 실행하지 않는다 — Application 이 이미 없어 finalizer 재조회가 NotFound 로 실패한다" >&2
    echo "  그 사이 새로 생긴 자원이면 사람이 먼저 확인한다" >&2
    return 1
  }
  echo "확인: $ns 에 기본 자원만 남았다"
}

# 데이터를 가진 자원은 따로 못 박는다. 인벤토리 대조가 이미 잡지만 손실이 가장 크므로
# 원인이 바로 보이게 메시지를 분리한다.
assert_no_pvc() {
  ns=$1
  if ! pvcs=$($K -n "$ns" get pvc --ignore-not-found -o name 2>&1); then
    echo "중단: $ns 의 PVC 조회가 실패했다 — $pvcs" >&2; return 1
  fi
  test -z "$pvcs" || {
    echo "중단: $ns 에 PVC 가 있다. namespace 를 지우면 이 볼륨도 사라진다 — $pvcs" >&2
    return 1
  }
  echo "확인: $ns 에 PVC 없음"
}

# 삭제 후 검사 — Deployment 를 실제로 지운 뒤에만 부른다.
assert_no_pull_secret_ref() {
  if ! pods=$(pull_secret_consumers 2>&1); then
    echo "중단: pull Secret 소비자 조회가 실패했다 — $pods" >&2; return 1
  fi
  if printf '%s\n' "$pods" | grep -q "$MOCK_APP-ghcr"; then
    echo "중단: pull Secret 참조가 남아 있다 — $pods" >&2; return 1
  fi
  echo "확인: pull Secret 참조 없음"
}

stage_mock_sse() {
  assert_ns_exists argocd
  assert_ns_exists "$MOCK_NS"
  # 삭제 전 1회 — dry-run 에서도 돌아 예상 밖 자원을 미리 보여준다.
  assert_no_pvc "$MOCK_NS"
  assert_ns_inventory_approved "$MOCK_NS"
  assert_sa_has_no_pull_secret
  assert_no_finalizer "$MOCK_APP"

  run_delete -n argocd delete application "$MOCK_APP" --wait=true --timeout=60s
  if test "$CONFIRM" = yes; then
    assert_absent "Application $MOCK_APP" -n argocd get application "$MOCK_APP"
  fi

  # 라우팅 → 워크로드 순서. Route 를 먼저 끊어 backend 없는 Route 를 남기지 않는다.
  run_delete -n "$MOCK_NS" delete httproute  "$MOCK_APP" --wait=true --timeout=60s
  run_delete -n "$MOCK_NS" delete gateway    "$MOCK_APP" --wait=true --timeout=60s
  run_delete -n "$MOCK_NS" delete deployment "$MOCK_APP" --cascade=foreground --wait=true --timeout=120s
  run_delete -n "$MOCK_NS" delete service    "$MOCK_APP" --wait=true --timeout=60s

  echo "--- 다른 Gateway 가 말려들지 않았는지 ---"
  $K get gateway,httproute -A
  $K -n traefik get pod -o wide
  if test "$CONFIRM" = yes; then
    assert_present "Gateway persona-app" -n "$APP_NS" get gateway persona-app
  fi

  # 완전한 부재는 Deployment 를 실제로 지운 뒤에만 성립한다. dry-run 에서는 Pod 가 그대로
  # 살아 있는 것이 정상이므로 이 검사를 돌리지 않는다.
  if test "$CONFIRM" = yes; then
    assert_no_pull_secret_ref
  fi
  run_delete -n "$MOCK_NS" delete secret "$MOCK_APP-ghcr"

  # 메인 흐름의 dry-run 은 "아직 아무것도 안 지운 상태" 다. 잔여물 검사를 강제하면
  # 정상 클러스터에서도 항상 실패하므로 여기서는 정보만 보여준다(round 6 원칙).
  mock_sse_finish_sequence no
  echo "mock SSE 단계 완료 (confirm=$CONFIRM)"
}

# namespace 삭제 직전 검사와 삭제. stage_mock_sse 의 마지막과 stage_mock_sse_finish 가
# 공유해 두 경로의 잔여물 판정이 어긋나지 않게 한다. 여기가 실제 방어선이다 —
# 인벤토리 게이트가 아니라 더 좁은 잔여물 검사를 쓴다.
#
# dry-run 처리 방식은 호출부에 따라 달라야 한다. stage_mock_sse 의 메인 흐름에서
# dry-run 은 "아직 아무것도 안 지운 상태" 라 잔여물 검사를 강제하면 정상 클러스터에서도
# 항상 실패한다(round 6 원칙). 반면 stage_mock_sse_finish 는 워크로드를 다시 지우지
# 않으므로 지금 상태가 곧 삭제 전제조건이다 — 거기서는 dry-run 도 검사를 실제로 통과해야
# "삭제 가능"이라는 확인이 의미가 있다. enforce_dry_run 으로 두 경우를 구분한다.
mock_sse_finish_sequence() {      # mock_sse_finish_sequence <enforce_dry_run:yes|no>
  enforce_dry_run=$1
  if test "$CONFIRM" = yes || test "$enforce_dry_run" = yes; then
    assert_no_pvc "$MOCK_NS"
    assert_ns_residue_only_defaults "$MOCK_NS"
  else
    echo "--- 현재 남은 자원 (dry-run, 정보용 — 실패해도 이 단계를 막지 않는다) ---"
    ns_inventory "$MOCK_NS" || return 1
  fi
  run_delete delete namespace "$MOCK_NS" --wait=true --timeout=180s
  if test "$CONFIRM" = yes; then
    assert_absent "namespace $MOCK_NS" get namespace "$MOCK_NS"
  fi
}

# mock SSE 정리가 namespace 삭제 직전에 멈춘 뒤 다시 이어서 끝내는 전용 단계.
#
# stage_mock_sse 를 처음부터 다시 실행하면 안 된다 — Application 은 이미 지워졌고,
# assert_no_finalizer 는 그 조회에 --ignore-not-found 를 쓰지 않으므로 NotFound 를
# 조회 실패로 보고 즉시 중단한다. "잠시 뒤 다시 실행한다" 는 안내가 실제로는 완료할 수
# 없는 경로였다. 이 단계는 Application·워크로드 삭제를 다시 시도하지 않고 마무리만 한다.
stage_mock_sse_finish() {
  if ! gone=$($K get namespace "$MOCK_NS" --ignore-not-found -o name 2>&1); then
    echo "중단: namespace $MOCK_NS 조회가 실패했다 — $gone" >&2; return 1
  fi
  if test -z "$gone"; then
    echo "확인: namespace $MOCK_NS 는 이미 없다 — 마무리할 것이 없다"
    return 0
  fi
  # 이 단계는 워크로드를 다시 지우지 않으므로 지금 상태가 곧 삭제 전제조건이다.
  # dry-run 에서도 PVC·잔여물 검사를 실제로 돌려, 확인 없이 --confirm 을 걸면 뒤집히는
  # 거짓 성공을 보고하지 않는다. 삭제 명령만 run_delete 의 기존 dry-run 분기로 미룬다.
  mock_sse_finish_sequence yes
  echo "mock SSE 마무리 완료 (confirm=$CONFIRM)"
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
  if printf '%s\n' "$all" | grep -E 'mock-sse|persona-migrate'; then
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
# stdout 과 stderr 를 분리해서 받을 때 쓰는 임시 파일. 매 호출마다 새로 만들지 않고
# 계속 덮어써 파일 수를 늘리지 않는다. ns_inventory·classify_event 가 쓴다.
STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/persona-cleanup-stderr.XXXXXX")
trap 'rm -f "$STDERR_FILE"' EXIT HUP INT TERM
case "$STAGE" in
  migration)       stage_migration ;;
  mock-sse)        stage_mock_sse ;;
  mock-sse-finish) stage_mock_sse_finish ;;
  nfs)             stage_nfs ;;
  verify)          stage_verify ;;
  *)               echo "알 수 없는 단계: $STAGE" >&2; usage ;;
esac
