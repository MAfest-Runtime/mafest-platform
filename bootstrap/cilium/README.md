# Cilium 부트스트랩

역할 분리·대안 비교는 [네트워크 트레이드오프](../../../tradeoff/05-networking.md)에 모았다.
아래 설치·MTU 수치는 과거 검증 기록이며 AWS 경로 검증 완료를 의미하지 않는다.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium \
  --version 1.20.1 \
  --namespace kube-system \
  -f values.yaml
```

## 기록된 부트스트랩 설정

| 설정 | 값 |
| --- | --- |
| `kubeProxyReplacement` | **false** |
| `gatewayAPI` / `ingressController` | **false** |
| `routingMode` | tunnel (VXLAN) |
| `MTU` | **1280** — 아래 실측 기록 참고 |
| `ipam.mode` | kubernetes — Node PodCIDR 사용 |
| `hubble` | 활성 — 드롭 원인 진단용 |

## MTU — 측정으로 확정됨

실측: `tailscale0` **1280** · LAN **1500** · VXLAN 오버헤드 **50 bytes**

### 인터페이스 MTU와 라우트 MTU는 다르다

Cilium은 `MTU` 값을 **인터페이스에는 그대로**, **파드 netns의 라우트에는 터널 오버헤드를
뺀 값**으로 적용한다. 실제 경로에 적용되는 것은 **라우트 값**이다.

`MTU: 1230`으로 두고 측정한 결과:

```
eth0 인터페이스   mtu 1230
default 라우트    mtu 1180        ← 실효값
sweep 경계        1150 OK / 1170 FAIL   (1180 − 28 = 1152)
```

### 확정값

| 설정 | 인터페이스 | 라우트(실효) | 캡슐화 후 | tailscale0 (1280) |
| --- | --- | --- | --- | --- |
| **1280** | 1280 | **1230** | 1280 | **정확히 맞음** |
| 1230 | 1230 | 1180 | 1230 | 50 낭비 |

**`MTU: 1280`** — underlay 기준값을 그대로 넣는 것이 맞다.

### 검증은 인터페이스가 아니라 라우트로 한다

```bash
kubectl exec <pod> -- ip link show eth0        # 참고용일 뿐
kubectl exec <pod> -- ip route get <대상 IP>    # ← 이것이 실효 MTU

# 경계 확인: route mtu − 28 이 최대 ICMP payload
kubectl exec p1 -- ping -c1 -M do -s 1202 <IP>   # 통과
kubectl exec p1 -- ping -c1 -M do -s 1203 <IP>   # 실패
```

### 실패 방식을 구분한다 — K8S-01의 핵심 기술

| 증상 | 의미 |
| --- | --- |
| `sendmsg: Message too large` | **로컬** 라우트/인터페이스가 거부. 패킷이 나가지 않음 |
| 타임아웃 · 무응답 | **경로 중간**에서 소실. PMTU 블랙홀 — 이것이 K8S-01이 다루는 상황 |

### 이 과정에서 배운 것

인터페이스 MTU만 보고 "설정값이 곧 파드 MTU"라고 결론 내렸다가 값을 1230으로 잘못
낮춘 적이 있다. **라우트를 측정하지 않아서 생긴 오진이었다.**
설정값도, 인터페이스 값도 정답이 아니며, `ip route get`이 답을 준다.

AWS 워커 조인 후에는 Tailscale 구간에서 같은 sweep을 다시 돌린다. 1280은 여유 없이
정확히 맞는 값이므로, outer 헤더가 IPv6(+20)로 잡히는 등의 이유로 경계에서 실패하면
1260 이하로 낮춰 재확인한다.

### 함정: ConfigMap 변경은 파드를 재시작시키지 않는다

`MTU`를 포함한 상당수 Cilium 설정은 **`cilium-config` ConfigMap에만 쓰이고
DaemonSet 파드 스펙에는 들어가지 않는다.** 따라서 `helm upgrade`를 해도 에이전트
파드는 그대로 돌고, 옛 설정으로 계속 동작한다.

실제로 겪은 순서:

```
helm upgrade (MTU 1280 → 1230)        → REVISION 2, "deployed"
kubectl rollout status ds/cilium      → "successfully rolled out"
kubectl get pods                      → cilium 파드 AGE 12m, RESTARTS 0   ← 재시작 안 됨
ip link show cilium_vxlan             → mtu 1280                          ← 안 바뀜
```

`rollout status`가 거짓말한 것은 아니다. **파드 템플릿이 바뀌지 않았으니 이미 최신이
맞다.** 도구는 정상을 보고했고 실제로는 아무 일도 일어나지 않았다.

해결:

```bash
kubectl -n kube-system rollout restart ds/cilium
```

`rollOutCiliumPods: true`를 values에 넣어 자동화했지만, helm은 알 수 없는 값을 조용히
무시하므로 이것에만 의존하지 않는다.

### Argo CD 도입 시 같은 문제가 재발한다

**이 클래스의 드리프트는 GitOps에서 더 위험하다.** Argo가 Cilium을 관리할 때
values에서 MTU만 바꾸면:

- ConfigMap이 갱신되고
- Argo는 **`Synced` · `Healthy`** 로 보고하며
- 에이전트는 **옛 설정으로 계속 동작한다**

선언과 실제가 어긋났는데 어느 대시보드도 그것을 알려주지 않는다.
그래서 다음을 규칙으로 둔다.

- Cilium 설정 변경 시 sync 후 **반드시 DaemonSet을 재시작**한다 (Argo sync hook 또는 수동)
- 검증은 Argo 상태가 아니라 **실제 인터페이스 값**으로 한다

### 이 발견의 의미

설정값을 넣었다고 끝이 아니라는 것을 실증한 사례다. 계산상 기대값(1230)과 실제
동작(1280)이 달랐고, **측정하지 않았으면 AWS 노드를 붙인 뒤에야 드러났을 문제**다.
K8S-01의 진단 서사에 그대로 쓸 수 있다.

## 과거 AWS 조인 검토 메모 — 적용 전 재검증

아래는 당시 주소 구성을 기준으로 한 후보이며 최종 적용 지시가 아니다.
AWS GPU 워커가 Tailscale 너머에서 조인하면 다음 접근 경로를 확인한다.

1. **`kubernetes` 서비스 EndpointSlice가 `192.168.50.101:6443`을 가리킨다.**
   AWS 노드는 이 LAN 주소에 도달할 수 없다. 홈 노드 하나를 Tailscale 서브넷 라우터로
   두어 `192.168.50.0/24`를 광고하고, AWS 노드에서만 그 경로를 수락하는 방식으로 푼다
2. **AWS 노드의 InternalIP를 Tailscale IP로 지정해야** 노드 간 VXLAN이 그 경로를 탄다
   (`kubelet --node-ip`)

현재 실행 순서는 [통합 기획](../../../docs/current-plan.md)을 따른다.
노드 InternalIP·API 접근·반환 경로를 함께 검증한 뒤 적용 방식을 확정한다.

## Tailscale이 Pod 대역을 연결 경로로 고르는 문제

GPU 노드 tailscaled가 `cilium_host`(Pod 대역) 주소를 연결 후보로 알리면 peer 경로가 공인 IP와
`10.244.x.x` 사이를 6~7초마다 오가고, 그 위의 TCP 스트림이 1~2분 멈춘다(VXLAN이 Tailscale 위를 지나
Tailscale 패킷이 자기 터널로 다시 들어가는 순환). Cilium 설정은 바꾸지 않고, 노드에서 Pod 대역과 오가는
Tailscale UDP를 버려 해결한다. 원인 증거, 적용·검증·되돌리기는
[tailscale-podcidr-guard](../tailscale-podcidr-guard/README.md)에 있다.

## 지표 수집과 ddns DNS 실패 계측

persona-edge/ddns-update가 FQDN 정책 아래에서 가끔 `Could not resolve host`로 실패한다.
10-19 14:30 건의 worker1 cilium-agent 로그에는 `forwarded proxied DNS lookup ... i/o timeout`
(Cilium DNS 프록시가 Pod 주소로 CoreDNS에 넘긴 질의의 응답이 안 돌아옴)이 있었고 같은 시간 CoreDNS의
SERVFAIL은 0이었다. 원인은 아직 모른다. 다음 실패 때 원인을 좁히려고 지표를 수집한다.

| 지표 | 포트 | 수집 선언 |
| --- | --- | --- |
| cilium-agent (`cilium_drop_count_total` 등) | 9962 | `prometheus.serviceMonitor` |
| Hubble (`hubble_drop_total`, `hubble_dns_*` 등) | 9965 | `hubble.metrics.serviceMonitor` |
| `src_valid_mark` | node-exporter 9100 | `helm/values/monitoring-stack.yaml`의 sysctl collector |

- 두 ServiceMonitor는 `release: monitoring-stack` 라벨이 있어야 Prometheus가 고른다.
- Hubble 지표 라벨은 source/destination namespace로 제한했다(`labelsContext`). 옵션을 주지 않으면 IP·workload가
  라벨에 들어가 시계열이 Pod 수에 따라 늘어난다. dns에는 `query` 옵션을 주지 않았다(도메인별 시계열 방지).
- 두 포트는 hostNetwork라 Pod 단위 NetworkPolicy 대상이 아니고, 저장소에 host firewall 선언도 없어
  NetworkPolicy는 바꾸지 않았다. node-exporter(9100)가 이미 같은 경로로 수집되고 있다.
  GPU 노드에서 막히는지는 노드에서 `sudo ufw status`, `sudo nft list ruleset | head -40`으로 확인한다.
- 렌더 확인: `sh scripts/validate-cilium-metrics-values.sh`(ServiceMonitor 2개·라벨·hubble 옵션),
  `sh scripts/validate-monitoring-manifests.sh`(node-exporter 인자), `sh scripts/validate-alert-rules.sh`(알림 규칙).

### 적용 순서와 재시작 영향

```bash
# 1) Cilium: 현재 values 전체를 다시 넘긴다. --reuse-values는 쓰지 않는다
#    (이전 릴리스에 남은 값과 이 파일이 섞여 어느 값이 적용됐는지 알 수 없게 된다)
cd bootstrap/cilium
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system -f values.yaml \
  --kube-context <context>
kubectl --context <context> -n kube-system rollout status ds/cilium

# 2) monitoring-stack Argo Sync (node-exporter 인자) — 수동 Sync 규약을 따른다
# 3) 알림 규칙: Argo가 아니라 CP에서 수동 적용한다(argocd/README.md 참고)
kubectl --context <context> apply -k kustomize/overlays/prod/traefik-observability
```

- `hubble-metrics` 설정이 ConfigMap 체크섬을 바꿔 **cilium-agent DaemonSet이 롤링 재시작**된다
  (`rollOutCiliumPods: true`). eBPF 데이터패스는 agent가 내려가도 유지되므로 기존 연결은 일반적으로 끊기지 않는다(이 클러스터에서 실측하지는 않았다).
- agent가 다시 뜨는 동안 정책을 재생성하고 **DNS 프록시도 agent와 함께 내려간다.** 이 사이에 FQDN 정책을 쓰는 Pod
  (ddns-update, oauth2-proxy)의 DNS 질의가 실패할 수 있다. ddns-update가 방금 성공한 직후에 적용하면
  다음 실행(5분 뒤)까지 여유가 있다.
- node-exporter DaemonSet도 재시작된다(수집 공백 1~2번).

### 적용 후 확인 (Prometheus에서)

```promql
count by (__name__)({__name__=~"cilium_drop_count_total|hubble_drop_total|hubble_dns_.*"})   # 비어 있지 않아야 한다
node_sysctl_net_ipv4_conf_all_src_valid_mark                                                    # 노드 4대 모두 0
```

### 다음 ddns 실패가 나면 (DdnsUpdateJobFailed 알림이 안내하는 항목)

실패 시각 앞뒤 15분 구간을 함께 기록한다.

```bash
kubectl --context <context> -n kube-system logs -l k8s-app=cilium --since=30m --tail=-1 \
  | grep "forwarded proxied DNS lookup"
```

```promql
sum by (reason) (increase(hubble_drop_total[30m]))
sum by (rcode) (increase(hubble_dns_responses_total[30m]))
node_sysctl_net_ipv4_conf_all_src_valid_mark
```
