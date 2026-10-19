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
# stderr 에 경고만 남기고 rc=0 로 계속 진행한다. Endpoints deprecation 경고처럼
# 성공한 조회에 stderr 가 섞이는 상황을 재현할 때 쓴다.
emit_warn() { echo "$1" >&2; }

# mock-sse-finish 사례는 독립된 새 프로세스 하나로 "이전 실행에서 이미 지워진 상태"를
# 흉내낸다. 그 안에서는 delete deployment 호출이 이번 CALL_LOG 에 남지 않으므로,
# 기존의 "grep -q 로그" 판정만으로는 워크로드가 이미 없다는 것을 알 수 없다.
case "$SCENARIO" in
  already-finished|finish-정상|finish-막힘|finish-pvc잔존) WORKLOAD_GONE=yes ;;
  *) WORKLOAD_GONE=no ;;
esac
workload_gone() { test "$WORKLOAD_GONE" = yes || grep -q "delete deployment persona-mock-sse" "$CALL_LOG"; }

# 공통 정상 응답
case "$*" in
  *"config current-context"*) echo "kubernetes-admin@kubernetes"; exit 0 ;;
esac

# ---- namespace 인벤토리 ------------------------------------------------------
# 실제 클러스터의 91개 kind 를 다 흉내낼 필요는 없다. 자원이 실제로 있는 kind 와
# 빈 kind 를 섞어, 스윕이 전 kind 를 돌고 결과를 모으는 경로를 검사한다.
INV_KINDS="pods replicasets.apps deployments.apps services endpoints secrets configmaps serviceaccounts persistentvolumeclaims gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io endpointslices.discovery.k8s.io ciliumendpoints.cilium.io podmetrics.metrics.k8s.io events events.events.k8s.io"

case "$SCENARIO" in
  api-resources-fail)
    case "$FAKE_ARGS" in
      *"api-resources"*) emit_err 'Error from server (Forbidden): api-resources is forbidden' ;;
    esac ;;
  kind-list-fail)
    case "$FAKE_ARGS" in
      *"get secrets --ignore-not-found"*) emit_err 'Error from server (Forbidden): secrets is forbidden' ;;
    esac ;;
esac

case "$FAKE_ARGS" in
  *"api-resources"*) printf '%s\n' $INV_KINDS; exit 0 ;;
esac

# 인벤토리 스윕의 kind 별 조회. 삭제된 것은 뒤의 상태 추적이 처리하므로 여기서는
# "지금 namespace 에 무엇이 있는가" 만 답한다.
case "$FAKE_ARGS" in
  *"-n persona-mock-sse get pods --ignore-not-found"*)
    if workload_gone; then
      case "$SCENARIO" in
        residue-pod) echo "pod/persona-mock-sse-6665f6c5bf-r575j" ;;
      esac
      exit 0
    fi
    echo "pod/persona-mock-sse-6665f6c5bf-r575j"
    case "$SCENARIO" in
      unrelated-pod|outsider-secret-ref) echo "pod/other-app-7d9f" ;;
      # 이름은 정리 대상처럼 보이지만 소유가 다른 Pod. 접두사 판정은 이것을 승인했다.
      prefix-pod) echo "pod/persona-mock-sse-independent" ;;
    esac
    exit 0 ;;
  *"-n persona-mock-sse get replicasets.apps --ignore-not-found"*)
    if workload_gone; then exit 0; fi
    echo "replicaset.apps/persona-mock-sse-6665f6c5bf"; exit 0 ;;
  *"-n persona-mock-sse get deployments.apps --ignore-not-found"*)
    if workload_gone; then
      case "$SCENARIO" in unrelated-deploy) echo "deployment.apps/other-app" ;; esac
      exit 0
    fi
    echo "deployment.apps/persona-mock-sse"
    case "$SCENARIO" in unrelated-deploy) echo "deployment.apps/other-app" ;; esac
    exit 0 ;;
  *"-n persona-mock-sse get persistentvolumeclaims --ignore-not-found"*|*"-n persona-mock-sse get pvc --ignore-not-found"*)
    case "$SCENARIO" in unrelated-pvc|finish-pvc잔존) echo "persistentvolumeclaim/other-data" ;; esac
    exit 0 ;;
  *"-n persona-mock-sse get secrets --ignore-not-found"*)
    if ! workload_gone && ! grep -q "delete secret persona-mock-sse-ghcr" "$CALL_LOG"; then
      echo "secret/persona-mock-sse-ghcr"
    fi
    case "$SCENARIO" in
      # 삭제 도중에 새 자원이 생긴 경우. namespace 삭제 직전 재검사가 잡아야 한다.
      late-resource) if grep -q "delete secret persona-mock-sse-ghcr" "$CALL_LOG"; then
                       echo "secret/appeared-later"
                     fi ;;
      # 같은 접두사를 쓴 무관한 Secret. 이름만 보던 판정은 이것을 승인했다.
      backup-secret) echo "secret/persona-mock-sse-backup" ;;
      late-backup-secret) if grep -q "delete secret persona-mock-sse-ghcr" "$CALL_LOG"; then
                            echo "secret/persona-mock-sse-backup"
                          fi ;;
    esac
    exit 0 ;;
  *"-n persona-mock-sse get ciliumendpoints.cilium.io --ignore-not-found"*)
    if workload_gone; then exit 0; fi
    echo "ciliumendpoint.cilium.io/persona-mock-sse-6665f6c5bf-r575j"; exit 0 ;;
  *"-n persona-mock-sse get podmetrics.metrics.k8s.io --ignore-not-found"*)
    if workload_gone; then exit 0; fi
    echo "podmetrics.metrics.k8s.io/persona-mock-sse-6665f6c5bf-r575j"; exit 0 ;;
  *"-n persona-mock-sse get configmaps --ignore-not-found"*)
    echo "configmap/kube-root-ca.crt"; exit 0 ;;
  *"-n persona-mock-sse get serviceaccounts --ignore-not-found"*)
    echo "serviceaccount/default"; exit 0 ;;
  *"-n persona-mock-sse get services --ignore-not-found"*)
    if test "$WORKLOAD_GONE" = yes || grep -q "delete service persona-mock-sse" "$CALL_LOG"; then exit 0; fi
    echo "service/persona-mock-sse"; exit 0 ;;
  *"-n persona-mock-sse get endpoints --ignore-not-found"*)
    # 실제 kubectl 은 Endpoints 를 별도 kind(endpoints/)로 반환한다. 예전엔 services 와
    # 같은 분기로 묶여 service/persona-mock-sse 를 냈고, 그래서 (c) 의 endpoints/$MOCK_APP
    # 승인 분기가 한 번도 실제로 검사되지 않았다.
    if test "$WORKLOAD_GONE" = yes || grep -q "delete service persona-mock-sse" "$CALL_LOG"; then exit 0; fi
    # 이 클러스터에서 실제로 나는 stderr 경고를 그대로 흉내낸다. 진짜 프로세스라 stdout·
    # stderr 가 실제 fd 로 분리되므로, ns_inventory 가 이를 올바르게 나누는지 검사할 수 있다.
    case "$SCENARIO" in
      endpoints-경고) emit_warn "Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice" ;;
    esac
    echo "endpoints/persona-mock-sse"; exit 0 ;;
  *"-n persona-mock-sse get events --ignore-not-found"*)
    if workload_gone; then
      case "$SCENARIO" in
        killing-event-연관)    echo "event/persona-mock-sse.killing" ;;
        killing-event-양쪽표현) echo "event/persona-mock-sse.killing" ;;
        무관한-event)          echo "event/other-app.warn" ;;
        finish-막힘)           echo "event/other-app.warn" ;;
      esac
    fi
    exit 0 ;;
  *"-n persona-mock-sse get events.events.k8s.io --ignore-not-found"*)
    # 이전엔 이 kind 에 실제 Event 를 반환하는 전용 핸들러가 없어 범용 fallback(항상
    # 빈 목록)이 대신 답했다. events.k8s.io/v1 은 core 와 참조 필드명이 달라(regarding
    # vs involvedObject) 실제로 열거되지 않으면 그 결함이 어떤 테스트에도 걸리지 않는다.
    if workload_gone; then
      case "$SCENARIO" in
        killing-event-grouped)  echo "event.events.k8s.io/persona-mock-sse.killing" ;;
        killing-event-양쪽표현) echo "event.events.k8s.io/persona-mock-sse.killing" ;;
        무관한-event-grouped)   echo "event.events.k8s.io/other-app.warn" ;;
      esac
    fi
    exit 0 ;;
  *"-n persona-mock-sse get gateways"*--ignore-not-found*)
    if test "$WORKLOAD_GONE" = yes || grep -q "delete gateway persona-mock-sse" "$CALL_LOG"; then exit 0; fi
    echo "gateway.gateway.networking.k8s.io/persona-mock-sse"; exit 0 ;;
  *"-n persona-mock-sse get httproutes"*--ignore-not-found*)
    if test "$WORKLOAD_GONE" = yes || grep -q "delete httproute persona-mock-sse" "$CALL_LOG"; then exit 0; fi
    echo "httproute.gateway.networking.k8s.io/persona-mock-sse"; exit 0 ;;
  *"-n persona-mock-sse get endpointslices"*--ignore-not-found*)
    if test "$WORKLOAD_GONE" = yes || grep -q "delete service persona-mock-sse" "$CALL_LOG"; then exit 0; fi
    echo "endpointslice.discovery.k8s.io/persona-mock-sse-kvh6v"; exit 0 ;;
esac

# ---- 소유 사슬 ---------------------------------------------------------------
# ---- uid 와 소유 참조 -------------------------------------------------------
# 실제 클러스터에서 읽은 값을 쓴다. 응답은 반드시 대상 이름에 따라 달라야 한다 —
# 이름과 무관하게 같은 값을 주면 소유 검사가 무력해지고 잘못된 구현도 통과한다.
DEPLOY_UID=d2e55dc8-b260-4597-b110-f2c9ea5aa846
RS_UID=54d0cd1e-4a3e-4d45-a0ee-b6208056793e
SVC_UID=6d365b08-43f8-4443-b045-16b7ab7a2609
POD_UID=3611c546-5f37-44c4-98d0-160be914dd2e
RS_NAME=persona-mock-sse-6665f6c5bf
POD_NAME=persona-mock-sse-6665f6c5bf-r575j

case "$FAKE_ARGS" in
  *"get deployment persona-mock-sse "*metadata.uid*) echo "$DEPLOY_UID"; exit 0 ;;
  *"get service persona-mock-sse "*metadata.uid*)    echo "$SVC_UID"; exit 0 ;;
  *"get replicaset "*metadata.uid*)
    t=$(printf '%s\n' "$FAKE_ARGS" | sed 's/.*get replicaset \([^ ]*\).*/\1/')
    test "$t" = "$RS_NAME" && { echo "$RS_UID"; exit 0; }
    echo "uid-of-$t"; exit 0 ;;
  *"get pod "*metadata.uid*)
    t=$(printf '%s\n' "$FAKE_ARGS" | sed 's/.*get pod \([^ ]*\).*/\1/')
    test "$t" = "$POD_NAME" && { echo "$POD_UID"; exit 0; }
    echo "uid-of-$t"; exit 0 ;;
esac

case "$FAKE_ARGS" in
  *"get pod "*ownerReferences*)
    t=$(printf '%s\n' "$FAKE_ARGS" | sed 's/.*get pod \([^ ]*\).*/\1/')
    case "$SCENARIO" in
      pod-wrong-owner)  echo "ReplicaSet|other-app-1234|uid-of-other-app-1234|true"; exit 0 ;;
      pod-uid-mismatch) echo "ReplicaSet|$RS_NAME|WRONG-UID|true"; exit 0 ;;
      pod-not-controller) echo "ReplicaSet|$RS_NAME|$RS_UID|false"; exit 0 ;;
    esac
    test "$t" = "$POD_NAME" && { echo "ReplicaSet|$RS_NAME|$RS_UID|true"; exit 0; }
    # 접두사만 같고 소유가 다른 Pod
    echo "ReplicaSet|other-app-1234|uid-of-other-app-1234|true"; exit 0 ;;
  *"get replicaset "*ownerReferences*)
    t=$(printf '%s\n' "$FAKE_ARGS" | sed 's/.*get replicaset \([^ ]*\).*/\1/')
    test "$t" = "$RS_NAME" && { echo "Deployment|persona-mock-sse|$DEPLOY_UID|true"; exit 0; }
    echo "Deployment|other-app|uid-of-other-app|true"; exit 0 ;;
  *"get endpointslice "*ownerReferences*)
    case "$SCENARIO" in
      eps-wrong-owner) echo "Service|other-svc|uid-of-other-svc|true"; exit 0 ;;
    esac
    echo "Service|persona-mock-sse|$SVC_UID|true"; exit 0 ;;
  *"get ciliumendpoint "*ownerReferences*)
    t=$(printf '%s\n' "$FAKE_ARGS" | sed 's/.*get ciliumendpoint \([^ ]*\).*/\1/')
    test "$t" = "$POD_NAME" && { echo "Pod|$POD_NAME|$POD_UID|"; exit 0; }
    echo "Pod|$t|uid-of-$t|"; exit 0 ;;
esac

case "$SCENARIO" in
  forbidden-secret)
    # 삭제 후 참조 부재 검사에서만 막는다. 삭제 전 대상 확인은 통과시켜야 그 지점까지 간다.
    case "$FAKE_ARGS" in
      *"-n persona-mock-sse get pod"*)
        if grep -q "delete deployment persona-mock-sse" "$CALL_LOG"; then
          emit_err 'Error from server (Forbidden): pods is forbidden'
        fi ;;
    esac ;;
  outsider-secret-ref)
    # 정리 대상이 아닌 Pod 가 pull Secret 을 참조하는 경우.
    # 이 Pod 는 namespace 에 실제로 있으므로 인벤토리 대조가 먼저 잡는다.
    case "$FAKE_ARGS" in
      *"-n persona-mock-sse get pod -o jsonpath"*)
        echo "persona-mock-sse-6665f6c5bf-r575j persona-mock-sse-ghcr,"
        echo "other-app-7d9f persona-mock-sse-ghcr,"
        exit 0 ;;
    esac ;;
  pod-wrong-owner)
    case "$FAKE_ARGS" in
      *"-n persona-mock-sse get pod -o jsonpath"*)
        echo "persona-mock-sse-imposter persona-mock-sse-ghcr,"
        exit 0 ;;
    esac ;;
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
  killing-event-연관)
    # Pod 종료 과정에서 남는 Killing 류 Event. involvedObject 가 정리 대상 Pod 를
    # 가리키므로 classify_event 가 승인해야 한다.
    case "$FAKE_ARGS" in
      *"get event persona-mock-sse.killing"*jsonpath*involvedObject*)
        echo "Pod|persona-mock-sse-6665f6c5bf-r575j"; exit 0 ;;
    esac ;;
  killing-event-grouped)
    # events.k8s.io/v1 은 involvedObject 가 아니라 regarding 을 쓴다. 이 필드로만
    # 열거되는 경우를 검사한다 — core 쪽 응답은 없다.
    case "$FAKE_ARGS" in
      *"get event.events.k8s.io persona-mock-sse.killing"*jsonpath*regarding*)
        echo "Pod|persona-mock-sse-6665f6c5bf-r575j"; exit 0 ;;
    esac ;;
  killing-event-양쪽표현)
    # 같은 Event 가 events 와 events.events.k8s.io 양쪽으로 동시에 열거되는 경우.
    # 두 필드(involvedObject·regarding)를 각각 올바르게 읽어야 둘 다 승인된다.
    case "$FAKE_ARGS" in
      *"get event persona-mock-sse.killing"*jsonpath*involvedObject*)
        echo "Pod|persona-mock-sse-6665f6c5bf-r575j"; exit 0 ;;
      *"get event.events.k8s.io persona-mock-sse.killing"*jsonpath*regarding*)
        echo "Pod|persona-mock-sse-6665f6c5bf-r575j"; exit 0 ;;
    esac ;;
  무관한-event|finish-막힘)
    # involvedObject 가 우리가 관리하지 않는 자원을 가리킨다. classify_event 가
    # 미승인으로 판정해야 한다.
    case "$FAKE_ARGS" in
      *"get event other-app.warn"*jsonpath*involvedObject*)
        echo "Pod|other-app-999"; exit 0 ;;
    esac ;;
  무관한-event-grouped)
    # regarding 이 우리가 관리하지 않는 자원을 가리킨다.
    case "$FAKE_ARGS" in
      *"get event.events.k8s.io other-app.warn"*jsonpath*regarding*)
        echo "Pod|other-app-999"; exit 0 ;;
    esac ;;
  already-finished)
    # mock-sse-finish 가 시작하자마자 보는 namespace 존재 확인. 이전 실행에서
    # namespace 삭제까지 이미 끝난 상태를 흉내낸다.
    case "$FAKE_ARGS" in
      *"get namespace persona-mock-sse --ignore-not-found"*) exit 0 ;;
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

# Deployment 를 지우면 그 Pod 도 사라진다. 이름 없는 목록 조회라 위 규칙으로는 안 잡히므로
# 따로 처리한다. 이것이 있어야 "삭제 후 참조 부재" 검사를 정상 경로에서 확인할 수 있다.
case "$FAKE_ARGS" in
  *"-n persona-mock-sse get pod"*)
    if grep -q "delete deployment persona-mock-sse" "$CALL_LOG"; then exit 0; fi ;;
esac

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
  # mock SSE Deployment 가 살아 있으므로 그 Pod 가 pull Secret 을 참조한다(정상).
  *"-n persona-mock-sse get pod"*)   echo "persona-mock-sse-6665f6c5bf-r575j persona-mock-sse-ghcr,"; exit 0 ;;
  *"-n persona-mock-sse get sa"*)    echo "default "; exit 0 ;;
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

# 소비자 조회 실패는 Secret·namespace 삭제로 이어지면 안 된다.
# Application·httproute·gateway·deployment·service 5건까지만 나간다.
run_case forbidden-소비자조회 forbidden-secret  mock-sse  yes nonzero 5 "소비자 조회가 실패했다"

# 정리 대상 밖의 Pod 가 pull Secret 을 쓰면 삭제 전에 멈춘다.
run_case 대상외-Secret소비자  outsider-secret-ref mock-sse yes nonzero 0 "승인 조건을 만족하지 않는"

# namespace 삭제는 그 안의 모든 것을 가져간다. pull Secret 을 참조하지 않는 자원도
# 승인 목록 밖이면 멈춘다. "소비자 없음" 과 "보존할 자원 없음" 은 다른 조건이다.
run_case 무관한-Pod          unrelated-pod      mock-sse  yes nonzero 0 "승인 조건을 만족하지 않는"
run_case 무관한-PVC          unrelated-pvc      mock-sse  yes nonzero 0 "PVC 가 있다"
run_case replicas0-Deployment unrelated-deploy  mock-sse  yes nonzero 0 "승인 조건을 만족하지 않는"
run_case Pod-소유자다름       pod-wrong-owner    mock-sse  yes nonzero 0 "승인 조건을 만족하지 않는"

# 인벤토리 조회가 실패하면 빈 목록으로 읽지 않는다.
run_case api-resources-실패   api-resources-fail mock-sse  yes nonzero 0 "api-resources 조회가 실패"
run_case kind-조회실패        kind-list-fail     mock-sse  yes nonzero 0 "조회가 실패했다"

# 삭제 도중에 새 자원이 생기면 namespace 삭제 직전 재검사가 잡는다.
# Application·httproute·gateway·deployment·service·secret 6건까지만 나간다.
run_case 삭제중-자원출현      late-resource      mock-sse  yes nonzero 6 "기본 자원 외의 것이 남아"

# 리뷰가 재현한 세 가지. 이름 접두사만 보던 판정은 셋 다 승인하고 namespace 까지 지웠다.
run_case 기존-백업Secret      backup-secret      mock-sse  yes nonzero 0 "승인 조건을 만족하지 않는"
run_case 무관한-접두사Pod     prefix-pod         mock-sse  yes nonzero 0 "승인 조건을 만족하지 않는"
run_case 삭제중-백업Secret    late-backup-secret mock-sse  yes nonzero 6 "기본 자원 외의 것이 남아"

# 소유 참조는 이름만이 아니라 uid 와 controller 까지 본다.
run_case Pod-소유UID불일치    pod-uid-mismatch   mock-sse  yes nonzero 0 "승인 조건을 만족하지 않는"
run_case Pod-controller아님   pod-not-controller mock-sse  yes nonzero 0 "승인 조건을 만족하지 않는"
run_case endpointslice-소유다름 eps-wrong-owner  mock-sse  yes nonzero 0 "승인 조건을 만족하지 않는"

# 삭제가 정착되지 않았거나 잔여물이 있으면 namespace 를 지우지 않는다.
run_case 잔여물-Pod남음       residue-pod        mock-sse  yes nonzero 6 "기본 자원 외의 것이 남아"

# 성공한 조회의 stderr 경고를 자원 이름으로 오판하면 안 된다. 이 클러스터에서 Endpoints
# 조회는 항상 이 경고를 낸다 — dry-run 의 사전 인벤토리 대조에서 실제로 겪는 경로다.
run_case endpoints-경고       endpoints-경고     mock-sse  no  0       0 "dry-run"

# Pod 종료 과정에서 남는 Event 는 involvedObject 가 우리가 관리하는 자원을 가리키면
# 허용해 정상 완료로 이어진다.
run_case killing-event-연관   killing-event-연관 mock-sse  yes 0       7 "mock SSE 단계 완료"

# involvedObject 가 우리가 관리하지 않는 자원을 가리키면 Event 라도 허용하지 않는다.
run_case 무관한-event        무관한-event       mock-sse  yes nonzero 6 "기본 자원 외의 것이 남아"

# events.k8s.io/v1 은 involvedObject 가 아니라 regarding 을 쓴다. 하나로만 조회하면
# 이 kind 는 필드가 없어 빈 값만 나오고 정상 Event 도 미승인으로 잡힌다.
run_case killing-event-grouped killing-event-grouped mock-sse yes 0      7 "mock SSE 단계 완료"

# 같은 Event 가 events 와 events.events.k8s.io 양쪽으로 동시에 열거되는 경우. 두
# 필드를 각각 올바르게 읽어야 둘 다 승인되고 정상 종료된다.
run_case killing-event-양쪽표현 killing-event-양쪽표현 mock-sse yes 0     7 "mock SSE 단계 완료"

# regarding 이 무관한 자원을 가리키면 grouped Event 라도 허용하지 않는다.
run_case 무관한-event-grouped 무관한-event-grouped mock-sse yes nonzero 6 "기본 자원 외의 것이 남아"

# 이름이 아니라 참조 필드를 봐야 잡힌다. 이름 검색 방식은 이 사례를 통과시켰다.
run_case VA-PV참조           va-references-pv   nfs       yes nonzero 0 "참조하는 VolumeAttachment 가 있다"

# 같은 이름의 PVC 가 재생성돼 다른 PV 에 붙으면 이번 승인 범위가 아니다.
run_case PVC-재생성          pvc-recreated      nfs       yes nonzero 0 "승인된 PV 와 다른 PV"

# PV 신원이 다르면 PVC·PV 삭제가 한 건도 나가면 안 된다.
run_case PV신원-불일치       pv-mismatch        nfs       yes nonzero 0 "신원이 기대값과 다르다"

# mock-sse 가 namespace 삭제 직전에 멈춘 뒤 다시 이어서 끝내는 전용 단계.
# 각 사례는 독립된 새 프로세스로 실행되므로 "이전 실행에서 이미 지워진 상태에서
# 재개한다" 는 시나리오를 그대로 검사한다 — mock-sse 를 처음부터 다시 실행하면
# 이미 없는 Application 조회가 NotFound 로 실패해 항상 중단됐다.
run_case 이미-완료됨         already-finished   mock-sse-finish yes 0       0 "마무리할 것이 없다"
run_case finish-정상         finish-정상        mock-sse-finish yes 0       1 "마무리 완료"
run_case finish-막힘         finish-막힘        mock-sse-finish yes nonzero 0 "기본 자원 외의 것이 남아"

# finish 단계는 워크로드를 다시 지우지 않으므로 지금 상태가 곧 삭제 전제조건이다.
# dry-run 도 PVC·잔여물 검사를 실제로 통과해야 "삭제 가능" 확인이 의미가 있다 — 이전엔
# dry-run 에서 검사를 건너뛰고 정보만 보여줘 --confirm 에서 뒤집히는 성공을 보고했다.

# 상태가 실제로 정리됐으면 dry-run 도 정상 종료해야 한다(거짓 성공이 아니라 확인된 성공).
run_case dry-run-finish-정상 finish-정상        mock-sse-finish no  0       0 "마무리 완료"

# normal 시나리오는 워크로드가 전혀 지워지지 않은 상태다. finish 는 그 상태를 다시
# 지우지 않으므로, dry-run 도 비정상 종료해야 정상이다 — 예전엔 정보만 보여주고
# rc=0 으로 끝나 "지금 --confirm 을 걸어도 되는지"를 알려주지 못했다.
run_case dry-run-mock-sse-finish normal         mock-sse-finish no  nonzero 0 "기본 자원 외의 것이 남아"

# 리뷰가 재현한 정확한 경우 — 워크로드는 이미 없지만 무관한 PVC 가 남았다. dry-run 이
# 여기서 멈춰야 --confirm 에서 뒤집히지 않는다.
run_case finish-dry-run-PVC잔존 finish-pvc잔존  mock-sse-finish no  nonzero 0 "PVC 가 있다"

# delete 개수만으로는 "Application 을 다시 건드리지 않았다" 는 핵심 주장을 증명하지
# 못한다. finish-정상 의 호출 로그에 워크로드·Application 삭제가 한 번도 없어야 한다.
if grep -qE 'delete application|delete deployment|delete service |delete httproute|delete gateway|delete secret' "$work/calls-finish-정상.log"; then
  echo "실패 [finish-호출없음]: mock-sse-finish 가 Application·워크로드 삭제를 다시 시도했다"
  sed 's/^/    호출: /' "$work/calls-finish-정상.log"
  exit 1
fi
echo "검출: finish-호출없음 (Application·워크로드 재시도 없음)"
pass=$((pass + 1))

# --confirm 없으면 어떤 단계도 삭제를 호출하지 않는다.
run_case dry-run-migration   normal             migration no  0       0 "dry-run"
run_case dry-run-mock-sse    normal             mock-sse  no  0       0 "dry-run"
run_case dry-run-nfs         normal             nfs       no  0       0 "dry-run"

# 정상 경로에서는 기대한 삭제가 실제로 나간다.
run_case 정상-migration      normal             migration yes 0       2 "migration 단계 완료"
run_case 정상-mock-sse       normal             mock-sse  yes 0       7 "mock SSE 단계 완료"
run_case 정상-nfs            normal             nfs       yes 0       2 "NFS 단계 완료"

echo "정리 게이트 실패 전파 테스트 ${pass}건 통과"
