#!/bin/sh
# cleanup-test-resources.sh 의 게이트가 실패를 뒤 단계까지 전파하는지 검사한다.
#
# 종료 코드만 보면 부족하다. 이전 판에는 게이트가 "중단:" 을 출력하고도 다음 삭제가
# 그대로 실행되는 결함이 있었고, 그때도 최종 종료 코드는 0이었다. 그래서 각 사례마다
# (1) 비정상 종료인지와 (2) 주입 지점 이후 delete 호출이 0건인지를 함께 본다.
#
# 가짜 kubectl 을 PATH 앞에 두고 모든 호출을 로그에 적는다. 클러스터에 접근하지 않는다.
set -eu
for tool in mktemp grep sed rm mkdir; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/persona-cleanup-guards.XXXXXX")
# 이 실행이 만든 임시 파일만 지운다. 저장소와 클러스터는 건드리지 않는다.
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/bin"

# ---- 가짜 kubectl ------------------------------------------------------------
# 모든 호출을 CALL_LOG 에 한 줄씩 적고, SCENARIO 에 따라 응답을 바꾼다.
cat > "$work/bin/kubectl" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$CALL_LOG"
FAKE_ARGS="$*"

emit_err() { echo "$1" >&2; exit 1; }

# 공통 정상 응답
case "$*" in
  *"config current-context"*) echo "kubernetes-admin@kubernetes"; exit 0 ;;
esac

case "$SCENARIO" in
  job-running)
    case "$FAKE_ARGS" in
      *"get job persona-migrate"*conditions*)
        echo '||1|0|ghcr.io/mafest-runtime/persona-minimal-api@sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6'
        exit 0 ;;
    esac ;;
  job-failed)
    case "$FAKE_ARGS" in
      *"get job persona-migrate"*conditions*)
        echo '|True||0|ghcr.io/mafest-runtime/persona-minimal-api@sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6'
        exit 0 ;;
    esac ;;
  job-image-mismatch)
    case "$FAKE_ARGS" in
      *"get job persona-migrate"*conditions*)
        echo 'True|||1|ghcr.io/mafest-runtime/persona-minimal-api@sha256:0000000000000000000000000000000000000000000000000000000000000000'
        exit 0 ;;
    esac ;;
  va-references-pv)
    # 이름에는 PV 가 안 들어가지만 참조 필드는 대상 PV 다.
    # 실제 kubectl 처럼 질의 형태에 따라 응답을 나눈다. 같은 출력을 주면 이름 대조 방식과
    # 참조 필드 대조 방식을 구분하지 못해, 잘못된 검사도 이 사례를 통과한다.
    case "$FAKE_ARGS" in
      *"get volumeattachment"*persistentVolumeName*)
        echo "csi-123abc pvc-96341d34-df4e-4a1e-8d74-3b91ccf5be15"; exit 0 ;;
      *"get volumeattachment"*)
        echo "volumeattachment.storage.k8s.io/csi-123abc"; exit 0 ;;
    esac ;;
  pvc-recreated)
    # 같은 이름의 PVC 가 재생성돼 다른 PV 에 결속된 경우
    case "$FAKE_ARGS" in
      *"jsonpath={.spec.volumeName}"*)
        echo "pvc-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"; exit 0 ;;
    esac ;;
  credential-helper)
    # 부재 확인 조회만 자격증명 도구 오류로 만든다. finalizer 조회(jsonpath)는 통과시켜야
    # assert_absent 까지 도달한다. 문자열로 "not found" 를 찾던 옛 방식은 이 오류를
    # 리소스 부재로 인정해 그대로 진행했다.
    case "$FAKE_ARGS" in
      *jsonpath*) ;;
      *"get application persona-migrate"*)
        emit_err 'Unable to connect to the server: getting credentials: executable credential-helper not found' ;;
    esac ;;
  finalizer-present)
    case "$*" in
      *"jsonpath={.metadata.finalizers}"*) echo '["resources-finalizer.argocd.argoproj.io"]'; exit 0 ;;
    esac ;;
  still-exists)
    # 삭제했는데 부재 확인 조회에 그대로 남아 있는 경우.
    # finalizer 조회(jsonpath)까지 가로채지 않도록 --ignore-not-found 형태만 맞춘다.
    case "$*" in
      *"get application persona-migrate --ignore-not-found"*)
        echo "application.argoproj.io/persona-migrate"; exit 0 ;;
    esac ;;
  cascade-violation)
    # Application 을 지웠더니 Job 까지 사라진 경우 (비연쇄 전제 위반).
    # 완료 상태 조회(conditions)까지 가로채면 그 앞 게이트에서 멈춰 이 사례를 검사하지 못한다.
    case "$FAKE_ARGS" in
      *conditions*) ;;
      *"get job persona-migrate"*) exit 0 ;;
    esac ;;
  pv-mismatch)
    case "$*" in
      *"get pv "*jsonpath*claimRef*)
        echo "persona-nfs-test/nfs-smoke-data 20Gi Retain nfs-shared 192.168.50.205 /srv/nfs/k8s pvc-96341d34-df4e-4a1e-8d74-3b91ccf5be15"
        exit 0 ;;
    esac ;;
  missing-ns)
    case "$*" in
      *"get namespace"*) exit 0 ;;   # --ignore-not-found: rc=0 + 빈 출력
    esac ;;
esac

# 이미 지운 대상은 다시 조회되지 않아야 한다. 호출 로그를 상태로 써서 흉내낸다.
# 이것이 없으면 삭제 후 부재 확인이 계속 "아직 있다" 로 나와 정상 경로를 검사할 수 없다.
set -- $*
kind=""; name=""
while test $# -gt 0; do
  case "$1" in
    get|delete)
      kind=${2:-}
      case "${3:-}" in -*|"") name="" ;; *) name=$3 ;; esac
      break ;;
  esac
  shift
done
if test -n "$kind" && test -n "$name" && grep -q "delete $kind $name" "$CALL_LOG"; then
  exit 0      # --ignore-not-found 의 부재 응답: rc=0 + 빈 출력
fi

# 시나리오가 가로채지 않은 조회의 기본 정상 응답.
# 정리 전 정상 운영 상태를 그대로 흉내낸다. 예전에는 get pod 가 늘 빈 목록이라
# "dry-run 에서 Pod 가 pull Secret 을 참조하는 것이 정상" 이라는 사실을 놓쳤다.
case "$FAKE_ARGS" in
  *"get namespace"*)                 echo "namespace/x"; exit 0 ;;
  *"jsonpath={.metadata.finalizers}"*) exit 0 ;;
  *"jsonpath={.spec.volumeName}"*)   echo "pvc-96341d34-df4e-4a1e-8d74-3b91ccf5be15"; exit 0 ;;
  *"jsonpath={.status.phase}"*)      echo "Released"; exit 0 ;;
  *"get pv "*jsonpath*claimRef*)
    echo "persona-nfs-test/nfs-smoke-data 1Gi Retain nfs-shared 192.168.50.205 /srv/nfs/k8s pvc-96341d34-df4e-4a1e-8d74-3b91ccf5be15"
    exit 0 ;;
  # attachRequired=false 라 실제로도 0건이다.
  *"get volumeattachment"*)          exit 0 ;;
  # migration Job: Complete=True, Failed 없음, 활성 없음, succeeded=1, 승인된 digest
  *"get job persona-migrate"*conditions*)
    echo 'True|||1|ghcr.io/mafest-runtime/persona-minimal-api@sha256:922ae043feaa1a893336816c38ac17f448aa96c44ba06983652181784f52c2f6'
    exit 0 ;;
  *"get job persona-migrate"*)       echo "job.batch/persona-migrate-0001-persona-minimal"; exit 0 ;;
  *"get all -A"*)                    echo "pod/persona-gateway-1"; exit 0 ;;
  *"get gateway persona-app"*)       echo "gateway.gateway.networking.k8s.io/persona-app"; exit 0 ;;
  *delete*)                          exit 0 ;;
  *get*|*rollout*)                   exit 0 ;;
esac
exit 0
FAKE
chmod +x "$work/bin/kubectl"

# ---- 검사 도우미 -------------------------------------------------------------
pass=0

# 삭제가 실제로 나갔는지 센다. dry-run 출력("[dry-run] 실행 예정")은 호출이 아니므로
# 로그에 남지 않는다. 로그에 남은 delete 만 진짜 호출이다.
count_deletes() { grep -c ' delete ' "$1" 2>/dev/null || true; }

run_case() {     # run_case <사례명> <시나리오> <단계> <confirm> <기대종료> <기대delete수> <기대메시지>
  name=$1; scenario=$2; stage=$3; confirm=$4; want_rc=$5; want_deletes=$6; want_msg=$7
  log="$work/calls-$name.log"; out="$work/out-$name.log"
  : > "$log"
  set +e
  if test "$confirm" = yes; then
    PATH="$work/bin:$PATH" CALL_LOG="$log" SCENARIO="$scenario" \
      sh "$repo_dir/scripts/cleanup-test-resources.sh" "$stage" --confirm > "$out" 2>&1
  else
    PATH="$work/bin:$PATH" CALL_LOG="$log" SCENARIO="$scenario" \
      sh "$repo_dir/scripts/cleanup-test-resources.sh" "$stage" > "$out" 2>&1
  fi
  rc=$?
  set -e

  deletes=$(count_deletes "$log")
  if test "$want_rc" = nonzero; then
    test "$rc" -ne 0 || { echo "실패 [$name]: 정상 종료했다 (rc=$rc)"; sed 's/^/    /' "$out"; exit 1; }
  else
    test "$rc" -eq 0 || { echo "실패 [$name]: 비정상 종료했다 (rc=$rc)"; sed 's/^/    /' "$out"; exit 1; }
  fi
  test "$deletes" -eq "$want_deletes" || {
    echo "실패 [$name]: delete 호출 $deletes 건, 기대 $want_deletes 건"
    sed 's/^/    호출: /' "$log"; exit 1; }
  if test -n "$want_msg"; then
    grep -q "$want_msg" "$out" || {
      echo "실패 [$name]: 기대 메시지가 없다 — $want_msg"; sed 's/^/    /' "$out"; exit 1; }
  fi
  echo "검출: $name (rc=$rc, delete=$deletes)"
  pass=$((pass + 1))
}

# ---- 사례 -------------------------------------------------------------------
# 게이트가 실패하면 그 뒤 삭제가 한 건도 나가면 안 된다.
run_case finalizer-있음      finalizer-present  migration yes nonzero 0 "finalizer 가 있다"
# Application 삭제(1건) 뒤 부재 확인이 자격증명 오류를 만나면 Job 삭제로 넘어가면 안 된다.
run_case credential-helper오류 credential-helper migration yes nonzero 1 "조회가 실패했다"
run_case namespace-부재      missing-ns         migration yes nonzero 0 "namespace argocd 가 없다"

# Application 삭제(1건) 뒤 게이트가 막히면 Job 삭제는 나가지 않는다.
run_case 삭제후-잔존         still-exists       migration yes nonzero 1 "아직 있다"
run_case 비연쇄-위반         cascade-violation  migration yes nonzero 1 "이(가) 없다"

# migration Job 이 끝나지 않았으면 삭제가 한 건도 나가면 안 된다.
# 같은 이름으로 다시 도는 migration 을 끊는 것이 가장 큰 사고다.
run_case Job-실행중          job-running        migration yes nonzero 0 "Complete 가 아니다"
run_case Job-실패            job-failed         migration yes nonzero 0 "Failed 다"
run_case Job-이미지불일치     job-image-mismatch migration yes nonzero 0 "이미지가 기대값과 다르다"

# 이름이 아니라 참조 필드를 봐야 잡힌다. 이름 검색 방식은 이 사례를 통과시켰다.
run_case VA-PV참조           va-references-pv   nfs       yes nonzero 0 "참조하는 VolumeAttachment 가 있다"

# 같은 이름의 PVC 가 재생성돼 다른 PV 에 붙으면 이번 승인 범위가 아니다.
run_case PVC-재생성          pvc-recreated      nfs       yes nonzero 0 "승인된 PV 와 다른 PV"

# PV 신원이 다르면 PVC·PV 삭제가 한 건도 나가면 안 된다.
run_case PV신원-불일치       pv-mismatch        nfs       yes nonzero 0 "신원이 기대값과 다르다"

# --confirm 없으면 어떤 단계도 삭제를 호출하지 않는다.
run_case dry-run-migration   normal             migration no  0       0 "dry-run"
run_case dry-run-nfs         normal             nfs       no  0       0 "dry-run"

# 정상 경로에서는 기대한 삭제가 실제로 나간다.
run_case 정상-migration      normal             migration yes 0       2 "migration 단계 완료"
run_case 정상-nfs            normal             nfs       yes 0       2 "NFS 단계 완료"

echo "정리 게이트 실패 전파 테스트 ${pass}건 통과"
