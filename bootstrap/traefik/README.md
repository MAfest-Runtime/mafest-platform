# Traefik — Gateway API 컨트롤러

선택 이유·NGINX와의 비교는 [트레이드오프 문서](../../../tradeoff/01-traefik-vs-nginx.md)에 모았다.
이 문서는 부트스트랩 절차·차트 검증 기록이다. 실제 values와 아래 목표 정책이 다를 수 있으므로 렌더 결과를 확인한다.

## 설치 순서

Gateway API CRD가 **먼저** 있어야 한다. CRD는 단일 소유자 원칙을 지킨다 —
Cilium과 Traefik이 각자 관리하려 들면 Argo sync가 충돌한다.

```bash
# 1) Gateway API CRD (standard channel, 버전 고정)
curl -s https://api.github.com/repos/kubernetes-sigs/gateway-api/releases/latest \
  | grep '"tag_name"'
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/<TAG>/standard-install.yaml

# 2) Traefik — 커스텀 PriorityClass 설치는 보류
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm search repo traefik/traefik --versions | head -3
```

## 설치 전에 렌더링을 확인한다

**helm은 알 수 없는 values를 조용히 무시한다.** Cilium에서 이미 겪었다
(`MTU` 변경이 ConfigMap에만 반영되고 파드는 그대로 돌았다).
차트 버전마다 키 이름이 다르므로 설치 전에 실제로 반영되는지 본다.

```bash
helm template traefik traefik/traefik --version <VER> -n traefik -f values.yaml \
  | grep -E 'nodeSelector|priorityClassName|type: ClusterIP|kubernetesGateway' -A2
```

기대한 항목이 안 보이면 그 키는 무시된 것이다. 차트 문서를 확인하고 고친다.

```bash
helm install traefik traefik/traefik --version <VER> \
  -n traefik --create-namespace -f values.yaml
```

## 현재 목표 정책

2026-09-17 공개 진입 결정 이후: 이전엔 "public inbound 0 원칙, NodePort/LoadBalancer 금지"였다.
이제 MetalLB가 있는 LoadBalancer 1개만 허용하고, NodePort 자동 할당은 `allocateLoadBalancerNodePorts:
false`로 막는다. 자세한 값은 [공개 진입 런북](../../runbooks/public-ingress.md) Gate 3 참고.

| 설정 | 값 | 이유 |
| --- | --- | --- |
| `service.spec.type` | **LoadBalancer** | MetalLB VIP(192.168.50.240)로 공유기 443 포워딩을 받는다. NodePort/ClusterIP였던 이전 값은 뒤집혔다 |
| `service.spec.allocateLoadBalancerNodePorts` | **false** | LoadBalancer 타입이 자동으로 여는 서비스 포트별 NodePort를 막는다. 자동 NodePort는 0이지만, `externalTrafficPolicy: Local`이 별도로 여는 healthCheckNodePort 1개(LAN 전용, kube-proxy가 여는 정상 동작)는 이 설정으로 막히지 않는다 |
| `providers.kubernetesGateway` | true | Gateway API만 사용 |
| `providers.kubernetesIngress` / `kubernetesCRD` | false | 진입 경로를 하나로 고정 |
| `gateway.enabled` | false | Gateway 리소스는 우리가 선언·버전관리 |
| 배치·replica | 2개, 두 홈 워커에 1개씩 **필수 분산**(`requiredDuringScheduling` podAntiAffinity) | `externalTrafficPolicy: Local`에서는 Pod가 몰리면 VIP도 한 노드에 묶인다. 2026-10-18 조회에서 두 Pod가 같은 노드에 있었다 |
| 업데이트 방식 | `maxSurge: 0`, `maxUnavailable: 1` | 필수 분산에서는 surge Pod가 갈 노드가 없어 기본값이면 업데이트가 멈춘다 |
| PodDisruptionBudget | `minAvailable: 1` | drain 같은 eviction만 제한한다. 롤링 업데이트와 노드 장애의 생존을 보장하지는 않는다 |
| `priorityClassName` | 빈 문자열 | 커스텀 우선순위 튜닝은 자원 압박 측정 뒤로 보류 |

2026-09-11 승인에 따라 로컬 values의 커스텀 우선순위를 해제했다. 실제 Helm 릴리스와
실행 중인 Pod에 반영된 것은 아니다. 후속 CP 작업에서 기존 values와 렌더 결과를 비교한 뒤
승인된 Helm 업데이트로 적용한다. 기존 PriorityClass 리소스와 Kubernetes 시스템 우선순위는 삭제하지 않는다.

## 분산 배치 강제 적용 절차

values 변경은 저장소에만 반영되어 있고 클러스터에는 사용자가 적용한다. `<ctx>`는 홈 클러스터의
kube context 이름이다. 터미널 기본 context가 다른 클러스터일 수 있으므로 모든 명령에 명시한다.

```bash
# 0) 대상 클러스터 확인과 현재 상태 기록
kubectl config get-contexts
kubectl --context <ctx> get nodes
kubectl --context <ctx> -n traefik get pod -o wide
kubectl --context <ctx> -n metallb-system get servicel2statuses -o wide 2>/dev/null   # VIP 광고 노드

# 0-1) 복구 지점 기록 (rollback에 쓸 revision과 현재 값)
helm --kube-context <ctx> -n traefik history traefik
helm --kube-context <ctx> -n traefik get values traefik > traefik-values-before.yaml

# 1) 별도 터미널에서 공개 경로를 1초 간격으로 확인해 끊김을 잰다
while true; do printf '%s ' "$(date +%T)"; curl -sk -o /dev/null -w '%{http_code}\n' --max-time 2 https://app.personaruntime.xyz/healthz; sleep 1; done

# 2) 업그레이드 (values 전체 재전달, --reuse-values 쓰지 않음)
helm --kube-context <ctx> upgrade traefik traefik/traefik --version 41.4.0 -n traefik -f bootstrap/traefik/values.yaml
kubectl --context <ctx> -n traefik rollout status deploy/traefik --timeout=5m

# 3) 확인
kubectl --context <ctx> -n traefik get pod -o wide      # worker1, worker2 각 1개
kubectl --context <ctx> -n traefik get pdb
kubectl --context <ctx> -n metallb-system get servicel2statuses -o wide 2>/dev/null
```

- 복구: `helm --kube-context <ctx> -n traefik rollback traefik <0-1에서 기록한 revision>`. 복구 뒤에도
  Pod 배치와 PDB를 같은 방식으로 확인한다.
- 필수 규칙과 `maxUnavailable: 1` 조합이면 롤아웃 중 worker2의 Pod가 하나씩 교체되며 새 Pod가
  worker1로 갈 것으로 예상한다. 별도 Pod 삭제 없이 재분산되는지는 결과로 확인한다.
- 1번 터미널의 실패 줄 수와 시각을 기록한다.
- 쏠림 감지 규칙(`kustomize/overlays/prod/traefik-observability`)은 `kubectl apply -k`로 CP에서
  수동 적용한다([argocd/README](../../argocd/README.md)). 적용 뒤 Prometheus UI Alerts 탭에서 확인한다.
  CoreDNS는 이 변경의 대상이 아니다. 규칙은 쏠림을 보여 줄 뿐이고 재분산은 별도로 판단한다.

## 함정: 스키마 검증은 섹션별로만 걸린다

이 차트는 values 스키마가 있어 최상위의 잘못된 키는 **거부한다**.
`logs`(존재하지 않음, 올바른 키는 `log`와 `accessLog`)는 즉시 에러로 잡혔다.

그러나 **`service:` 섹션에는 `additionalProperties: false`가 없다.**
그래서 `service.type: ClusterIP`는 스키마를 통과한 뒤 **조용히 무시되었고**,
렌더 결과는 기본값 `LoadBalancer`였다. 올바른 키는 **`service.spec.type`**이다.

```
service:
  spec:
    type: ClusterIP     # service.type 이 아니다
```

LoadBalancer로 두면 컨트롤러가 없어 EXTERNAL-IP는 `<pending>`이지만
**NodePort가 함께 할당되어 모든 노드에 포트가 열린다.** 재구축으로 없애려던
ingress-nginx의 NodePort 30080/30443 상태로 그대로 되돌아간다.

**설치 전 `helm template`으로 잡아냈다.** 그냥 설치했다면 `kubectl get svc`를
보고 나서야 알았을 문제다. 스키마가 있는 차트라도 렌더링 확인을 건너뛰지 않는다.

## 검증

```bash
kubectl -n traefik get pods,svc -o wide
kubectl get gatewayclass                       # traefik이 Accepted 상태여야 함
kubectl get crd | grep gateway.networking.k8s.io
```

## Tailnet 노출은 별도 단계

Traefik Service가 ClusterIP이므로 클러스터 밖에서는 보이지 않는다.
노출은 `tailscale serve`가 노드 쪽에서 ClusterIP로 전달하는 방식으로 붙인다
(노드는 kube-proxy를 통해 ClusterIP에 도달할 수 있다).

Serve 유지와 Operator 보류의 근거는 [네트워크 선택](../../../tradeoff/05-networking.md)에 둔다.
Serve 호스트 위치·장애 처리는 미결이며 Traefik replica 증가만으로 해결되지 않는다.

## 2026-09-08 배치 변경 확인

실제 worker2 고정 1개에서 홈 워커 두 대 허용·2개·분산 권장으로 변경했다.
초기 `--reuse-values` + hostname `null`은 기존 nodeSelector를 제거하지 못했다.
현재 사용자 values 전체에서 nodeSelector를 비운 뒤 같은 차트 버전에 `--reset-values`로 다시 전달하여 해결했다.
`--reset-values`만 단독으로 실행하면 기존 사용자 설정을 잃을 수 있으므로 이 설명을 단독 적용 명령으로 해석하지 않는다.

최종 사용자 출력: worker1·worker2 각각 Traefik 1개 Ready/Running, ClusterIP 10.104.208.56 유지.
로컬 values의 개수·배치 조건을 이 결과에 맞췄다. 설치 전체 값의 완전한 동기화나 HTTP/SSE 검증 완료를 의미하지 않는다.
롤링 교체 중 쏠림과 단일 Pod 재생성 결과는 [트레이드오프 기록](../../../tradeoff/07-service-replicas.md)에 남겼다.
