# vLLM 네트워크·모델 cache 실행 계획

상태: 2026-09-25 결정, **2026-09-27 모델 cache seed 선언 완성**(`kustomize/overlays/prod/persona-model-cache`,
Argo Application 없음). 모델 cache seed는 운영자 보고로 완료됐다(2026-09-27).

**vLLM(`kustomize/overlays/prod/persona-vllm`, Argo Application 없음)** — 운영자 제공 결과로 확인한 것과
아직 확인하지 않은 것을 나눈다.

| 구분 | 항목 |
| --- | --- |
| 확인(운영자 제공, 2026-09-27) | non-root(10001)·read-only rootfs 조건의 vLLM 기동 |
| 확인(운영자 제공, 2026-09-27) | 실제 비스트리밍 추론 요청 성공 |
| 확인(운영자 제공, 2026-09-27) | control-plane → vLLM Service 경유 SSE 스트리밍, 마지막 `[DONE]` 수신 |
| 확인(운영자 제공, 2026-09-27) | vLLM Prometheus Target `UP` |
| 미확인 | NetworkPolicy 적용 뒤 허용·차단 동작(아래 "첫 적용·복구 절차") |
| 미확인 | Gateway 애플리케이션의 LLM mode 전환(선언은 llm·새 image로 완료, 적용 전. 아래 "Gateway LLM 전환") |
| 미확인 | 성능·과부하 실험(처리량·지연·동시성) |

**NetworkPolicy(2026-09-27)**: `persona-inference` 정책과 Gateway → vLLM egress를 첫 적용 가능한
선언으로 보완했다. 클러스터에는 아직 적용하지 않았다. FQDN allowlist는 만들지 않는다.

## 한 문장 결론

vLLM은 `persona-inference`에 격리하고, Gateway와 Prometheus만 vLLM Pod의 TCP 8000에
들어오게 한다. 모델은 vLLM이 인터넷에서 직접 받지 않고, GPU Node에 고정되는 local-path
PVC에 별도 seed Job이 고정 revision으로 미리 저장한다.

```text
Gateway ───────────────▶ vLLM :8000      실제 추론
Prometheus ─────────────▶ vLLM :8000      /metrics 수집
model-cache seed Job ───▶ 허용한 model FQDN 최초 다운로드
vLLM ───────────────────▶ model PVC       인터넷 없이 local model path 읽기
```

## 1. 왜 model download를 분리하는가

vLLM image pull은 Node의 container runtime이 수행하지만, 모델 파일 download는 실행 중인 Pod가
수행한다. `persona-inference`가 default-deny이면 이 Pod download는 당연히 차단된다.

vLLM 자체에 model download egress를 계속 열면, 모델이 언제·어디서 바뀌었는지와 추론 Pod의
외부 통신 범위를 함께 관리해야 한다. 대신 download 책임을 짧게 사라지는 seed Job 하나로
분리한다. seed가 성공한 뒤 vLLM은 local path만 읽으므로 steady state에는 외부 model egress가
없다.

이 선택은 seed Job image·고정 model revision·검증 방법을 별도로 정해야 하는 비용을 수용한다.
그러나 vLLM 서비스가 재시작할 때마다 인터넷 상태에 의존하지 않는다는 이점이 더 크다.

## 2. model cache 저장 위치

cache는 `persona-vllm-model-cache` PVC로 둔다.

- StorageClass는 기존 `local-path`다. `WaitForFirstConsumer`이므로 seed Job이 GPU Node에
  스케줄된 뒤에만 그 Node에 PV가 생긴다.
- seed Job과 vLLM Deployment는 같은 GPU Node selector·taint toleration을 사용한다.
- cache PVC는 `ReadWriteOnce`이며, seed Job이 완료된 뒤에만 vLLM이 mount한다. 두 workload를
  동시에 실행하지 않는다.
- vLLM에는 `/models`를 read-only로 mount하고, `/tmp`·runtime cache처럼 쓰기가 필요한 경로는
  `emptyDir`로 분리한다.
- local-path reclaim policy가 `Retain`이므로 Pod 재시작·EC2 stop/start에는 cache가 남을 수
  있다. EC2 terminate나 PVC/PV 수동 정리 뒤에는 다시 seed해야 한다.

local-path ConfigMap의 `nodePathMap`에 `persona-gpu-01` → `/opt/local-path-provisioner`를
추가했다(`bootstrap/local-path/configmap.yaml`). Git 선언에는 추가됐지만, bootstrap은 Argo 밖이므로 실제 클러스터 반영과 GPU PVC `Bound` 실측 전까지 완료가 아니다. 목록 밖 노드(control-plane 등)는
계속 provisioning이 실패하도록 기본 경로를 두지 않는다. hostPath를 vLLM Pod에 직접 mount해
우회하지 않는다.

## 3. 고정 label 계약

아래 label은 Deployment, Service, NetworkPolicy, PodMonitor가 똑같이 사용한다.

```yaml
app.kubernetes.io/name: persona-vllm
app.kubernetes.io/component: inference
app.kubernetes.io/part-of: persona-platform
```

model seed Job은 `component: model-cache-seed`로 분리한다. seed Job을 vLLM label로 만들면
vLLM용 ingress·metrics policy가 의도치 않게 seed Pod에도 적용될 수 있다.

## 4. 만들 NetworkPolicy

| 위치 | 정책 | 허용 흐름 | 목적 |
| --- | --- | --- | --- |
| `persona-app` | 기존 `allow-gateway` egress 확장 | Gateway → vLLM TCP 8000 | 실제 추론 |
| `persona-inference` | `default-deny` | 없음 | 기본 차단 |
| `persona-inference` | `allow-vllm-gateway` | Gateway Pod → vLLM TCP 8000 | 추론 ingress |
| `persona-inference` | `allow-vllm-metrics` | 실제 Prometheus Pod → vLLM TCP 8000 | `/metrics` scrape |
| `persona-inference` | `allow-vllm-dns` | vLLM Pod → CoreDNS TCP/UDP 53 | 내부 이름 해석 |
| `persona-inference` | `allow-model-seed-dns` | seed Job → CoreDNS TCP/UDP 53 | 최초 download 이름 해석 |
| `persona-inference` | Cilium FQDN egress | seed Job → 실행 시 확인한 model host만 HTTPS | 최초 download — **이번 범위 밖**(아래) |

표준 Kubernetes NetworkPolicy는 IP/Pod/namespace 기준이고 FQDN을 직접 표현하지 못한다.
model download만 CiliumNetworkPolicy의 FQDN 정책으로 별도 선언한다. 실제 다운로드 시 필요한
redirect·artifact host를 합성 seed run에서 먼저 기록한 뒤 허용 목록을 확정한다. 추측한 host
목록이나 `0.0.0.0/0:443`은 넣지 않는다.

첫 seed는 inference 정책 없이 끝났으므로 FQDN 정책 없이 나머지 정책을 적용한다. **운영 제약**:
`allow-model-seed-dns` 하나만 적용돼도 seed Pod의 egress는 CoreDNS 53으로 제한된다(default-deny와
무관). 그 뒤에는 seed가 모델 호스트(HTTPS)에 닿지 못한다. seed를 다시 실행해야 하면(revision 변경·
cache 손상) 관측한 FQDN만 여는 별도 다운로드 허용 정책을 먼저 만들고 적용한다. 정책을 지워 우회하지
않는다.

**allow 정책만으로도 격리가 시작된다.** NetworkPolicy는 "허용 목록"이지만, 어떤 정책이 한 Pod의 한
방향(Ingress/Egress)을 고르는 순간 그 Pod의 그 방향은 격리되고 정책들이 허용한 흐름만 남는다.
default-deny는 그 격리를 namespace의 모든 Pod·양방향으로 넓힐 뿐이다.

| 정책 | 고르는 Pod·방향 | 적용 즉시 효과 |
| --- | --- | --- |
| `allow-vllm-gateway` | vLLM Ingress | vLLM 인입은 Gateway Pod TCP 8000만. `allow-vllm-metrics`가 아직 없으면 Prometheus 수집도 막힌다 |
| `allow-vllm-metrics` | vLLM Ingress | 위에 Prometheus Pod TCP 8000을 더한다 |
| `allow-vllm-dns` | vLLM Egress | vLLM 송출은 CoreDNS UDP/TCP 53만 |
| `allow-model-seed-dns` | seed Egress | seed 송출은 CoreDNS 53만 — 외부 HTTPS 차단 |
| `default-deny` | 모든 Pod 양방향 | 위 네 정책이 고르지 않은 Pod·방향(seed Ingress, 다른 Pod)까지 격리 |

`persona.runtime/apply-phase` label(allow·deny)은 `kubectl apply -l`로 **적용 묶음을 나누는 표시일 뿐**이다.
정책 엔진은 이 label을 보지 않고, 정책 사이에 평가 순서도 없다(적용된 정책의 허용 합집합만 본다).

**NetworkPolicy가 막지 못하는 것**: 표준 NetworkPolicy는 L3/L4(namespace·Pod·포트)만 본다.
vLLM은 추론 API와 `/metrics`를 같은 TCP 8000에서 내므로, Prometheus Pod에 8000을 열면 추론
경로에도 닿는다. Prometheus를 `/metrics` 경로로만 제한하는 것은 이 정책으로 하지 않는다.

### 선언이 실제로 어디에 있는가 (2026-09-25 작성, 2026-09-27 보완)

위 표 중 FQDN을 뺀 여섯 개는 매니페스트로 작성했다. 클러스터에는 아직 적용하지 않았다.

| 파일 | 상태 |
| --- | --- |
| `kustomize/overlays/prod/persona-model-cache/` | Namespace·model cache PVC·seed Job(2026-09-27). **Argo Application 없음** — 첫 seed는 사람이 적용. 예전 `bootstrap/namespaces/persona-inference.yaml`은 소유를 옮기며 지웠다 |
| `kustomize/base/networkpolicy/persona-inference/network-policy.yaml` | 작성. 정책 5개. 수동 적용 순서용 `persona.runtime/apply-phase` label(allow·deny) |
| `kustomize/overlays/prod/persona-inference-netpol/` | 작성. **Argo Application 없음** — 사람이 `kubectl apply -k`로 적용. Namespace는 만들지 않는다(model-cache overlay 소유) |
| `kustomize/base/networkpolicy/persona-app/network-policy.yaml` | `allow-gateway` egress에 vLLM TCP 8000 추가(2026-09-27). `persona-app-netpol` Argo Application 소유 |
| `kustomize/base/networkpolicy/persona-inference/network-policy-fqdn.yaml` | seed Job 전용 FQDN 허용(관측한 호스트 3개). 관측용 `allow-model-seed-observe.yaml`은 배선하지 않는다 |

`scripts/validate-networkpolicy-manifests.sh`가 렌더와 정책 모양을 검사하고,
`scripts/test-networkpolicy-manifests.sh`가 잘못된 변경(namespace만 허용, selector를 별도 peer로
분리, 포트 변경, 기존 Gateway 규칙 변경 등)을 잡는지 확인한다.

**Gateway → vLLM egress**: `allow-gateway`의 `egress` 끝에 한 규칙을 더했다. 대상은
`persona-inference` namespace AND `app.kubernetes.io/name=persona-vllm` Pod, TCP 8000 하나다.
namespaceSelector와 podSelector를 **같은 peer**에 둬야 AND다(별도 `-` 항목이면 OR). 기존 DB·
embedding·DNS·ingress 규칙은 그대로다. 이 파일은 `persona-app-netpol` Argo Application이
소유하므로 반영은 머지 뒤 그 Application의 Sync로만 한다. `kubectl patch`·`kubectl edit`로 live
정책을 고치지 않는다 — Git과 어긋나고 다음 Sync에서 되돌려진다.

### Prometheus selector — 실제 Prometheus Pod로 좁혔다 (2026-09-27)

`allow-vllm-metrics`는 `monitoring` namespace AND 아래 Pod label을 같은 peer에서 고른다.
라벨은 운영 클러스터의 Prometheus Pod에서 관측한 값이다.

```yaml
app.kubernetes.io/name: prometheus
app.kubernetes.io/instance: monitoring-stack-kube-prom-prometheus
```

- 좁힌 이유: vLLM은 추론 API와 `/metrics`를 같은 8000에서 낸다. namespace 전체를 열면 Grafana
  등 `monitoring`의 다른 Pod도 추론 API에 닿는다.
- Pod 이름·IP·controller revision hash는 재시작·업그레이드마다 바뀌므로 쓰지 않는다.
- 위험: 이 라벨은 kube-prometheus-stack 차트가 정하고 이 저장소가 선언하지 않는다. 차트
  업그레이드로 바뀌면 수집이 끊기고 vLLM Target이 `DOWN`이 된다. 업그레이드 뒤 Target을 확인하고
  selector를 함께 고친다.
- 기존 세 선례(`traefik/allow-ingress-metrics`, `persona-data`의 exporter 허용,
  `persona-app/allow-gateway-metrics`)는 namespace 라벨만 쓰며 이번에 바꾸지 않았다. 관례가
  다르다는 점은 남는다.

## 5. 배포·Sync 순서

1. GPU Node 조인 후 Cilium·kube-proxy가 custom taint를 tolerate하는지 확인한다.
2. `persona-gpu-01`용 local-path nodePathMap 변경(Git 선언은 추가됨)을 control-plane에서 반영하고,
   GPU 노드에 고정한 PVC가 `Bound`되는지 확인한다. bootstrap이라 Argo Sync 대상이 아니다.
3. control-plane에서 `kubectl apply -k kustomize/overlays/prod/persona-model-cache`로 Namespace·
   model cache PVC·seed Job을 적용한다(Argo 아님). **inference NetworkPolicy보다 먼저다** — 다운로드
   호스트를 아직 모르므로, default-deny가 없는 상태의 첫 seed에서 실제 호스트를 관측한다.
4. 첫 seed 결과를 기록한다: Job `Complete`, 완료 marker(`.persona-seed-complete.json`)와 manifest,
   PVC bound Node, 그리고 Hubble·DNS 로그로 seed Pod가 질의·접속한 호스트 목록. token·원문은
   로그에 남기지 않는다. seed가 실패하면 재시도로 덮지 않고 원인(네트워크·용량·무결성)부터 본다.
5. `persona-inference` NetworkPolicy를 적용한다(아래 "첫 적용·복구 절차"). 첫 seed가 끝났으므로
   FQDN 정책 없이 적용한다. seed 재실행에는 별도 다운로드 허용 정책이 먼저 필요하다(§4).
6. `persona-app-netpol`의 Gateway egress를 Argo에서 Sync한다(기존 소유 경로). 기존 DB·embedding·DNS
   경로는 바꾸지 않는다.
7. seed 완료를 확인한 뒤 local model path를 쓰는 vLLM Deployment·Service·PodMonitor를 적용한다
   (`kustomize/overlays/prod/persona-vllm`. 운영자 제공 결과로 기동·추론·Target `UP` 확인, 맨 위 상태 표).
   - 모델 cache PVC를 read-only로 붙이고, initContainer가 seed marker·manifest·weight index를 확인하지
     못하면 vLLM을 시작하지 않는다.
   - `vllm serve <로컬 절대 경로>`, `--served-model-name Qwen/Qwen3-4B-Instruct-2507`,
     `--max-model-len 4096`, `--gpu-memory-utilization 0.85`(초기값, 실측 전), `--no-enable-log-requests`.
     vLLM v0.29.0에는 `--disable-log-requests`가 없어 쓰면 기동이 실패한다.
   - `HF_HUB_OFFLINE`·`TRANSFORMERS_OFFLINE`·`VLLM_NO_USAGE_STATS`로 재시작 때 외부에 기대지 않는다.
   - replicas 1·Recreate(GPU 한 장을 기존 Pod가 점유해 RollingUpdate의 새 Pod가 Pending될 수 있다),
     non-root 10001·read-only rootfs, `/tmp`·`/dev/shm` emptyDir.
   - 확인 범위: 이 Deployment 조건(non-root 10001·read-only rootfs)의 GPU 기동과 비스트리밍 추론,
     Service 경유 SSE `[DONE]`까지 운영자 제공 결과로 확인했다(2026-09-27).
8. NetworkPolicy를 적용하고 아래 "다음 실측 항목" a–d를 확인한다.

### 첫 적용·복구 절차 (control-plane에서 사람이 수행, 아직 실행하지 않음)

`kubectl apply`는 Argo의 sync-wave annotation을 읽지 않는다. `-k`로 overlay 전체를 한 번에 적용하면
default-deny와 allow 정책이 함께 들어간다. 그래서 `persona.runtime/apply-phase` label로 묶음을 나눠
**allow 4개를 먼저 적용해 확인하고, default-deny는 마지막에** 적용한다.

한 묶음 안에서도 적용은 원자적이지 않다. kubectl은 리소스를 하나씩 만들고 Cilium도 정책마다 따로
반영한다. 예를 들어 `allow-vllm-gateway`가 먼저 반영되고 `allow-vllm-metrics`가 아직이면 그 사이
Prometheus 수집이 한 번 실패할 수 있다. 적용 직후 한 번의 실패는 수 초 뒤 다시 확인해 판단한다.

1. **전제**: kubectl context가 운영 클러스터이고, `persona-inference` Namespace(model-cache overlay 소유)와
   Ready인 vLLM Pod가 있다. `sh scripts/validate-networkpolicy-manifests.sh`가 통과한다.
2. **적용 전 상태 보관**: inference의 정책 목록과 내용을 저장소 밖 작업 디렉터리에 남긴다. 롤백의
   기준이 된다(정책 선언만 담기며 Secret이 아니다).
   ```sh
   kubectl -n persona-inference get networkpolicy,ciliumnetworkpolicy -o wide
   kubectl -n persona-inference get networkpolicy,ciliumnetworkpolicy -o yaml \
     > persona-inference-netpol-before.yaml
   ```
   이 절차는 **목록이 비어 있다는 전제**로 쓴다. 이미 정책이 있으면 아래 롤백의 "기존 정책이 있었을
   때"를 따르고, 같은 이름이 있으면 적용 전에 멈추고 차이를 먼저 본다.
3. **Gateway egress**: 이 변경이 머지된 뒤 Argo에서 `persona-app-netpol`을 Sync한다. `allow-gateway`는
   Argo 소유이므로 live patch하지 않는다. Sync 전에는 persona-app default-deny가 Gateway → vLLM
   egress를 막고 있다.
4. **inference allow 4개 적용**:
   ```sh
   kubectl apply -k kustomize/overlays/prod/persona-inference-netpol \
     -l persona.runtime/apply-phase=allow
   kubectl -n persona-inference get networkpolicy
   ```
   `allow-vllm-gateway`·`allow-vllm-metrics`·`allow-vllm-dns`·`allow-model-seed-dns` 4개만 있고
   `default-deny`가 없는지 본다. 이 시점부터 vLLM 양방향과 seed egress는 이미 격리돼 있다.
5. **allow 단계 확인** — 하나라도 실패하면 **default-deny로 진행하지 않고** 아래 롤백으로 간다.
   - Gateway Pod → vLLM Service `/health`가 200(실측 a).
   - Prometheus에서 vLLM Target이 `UP`으로 남는다. scrape 간격(30초) 두 번 이상 기다린다(실측 b).
   - vLLM Pod 안에서 내부 이름 해석이 된다(예:
     `kubectl -n persona-inference exec deploy/persona-vllm -c vllm -- python3 -c "import socket; print(socket.getaddrinfo('persona-vllm.persona-inference.svc.cluster.local', 8000)[0][4])"`).
   - Gateway Pod에서 짧은 비스트리밍 `/v1/chat/completions` 요청이 정상 응답한다(실측 d).
6. **default-deny 적용**:
   ```sh
   kubectl apply -k kustomize/overlays/prod/persona-inference-netpol \
     -l persona.runtime/apply-phase=deny
   ```
7. **deny 단계 확인**: 5단계의 허용 확인을 모두 반복하고, 차단 확인(실측 c)을 더한다. 실패하면 롤백한다.

**롤백 — 긴급 조치다.** 정책을 지우면 vLLM·seed의 접근 범위가 적용 전처럼 다시 넓어진다. 원인을 Git에서
고쳐 다시 적용할 때까지의 임시 상태로만 둔다.

- **default-deny만 지우는 것은 롤백이 아니다.** allow 4개가 남아 있으면 vLLM 양방향과 seed egress는 계속
  격리돼, 적용 전 상태로 돌아가지 않고 원인도 풀리지 않는다.
- **적용 전 inference 정책이 없었을 때(2단계 목록이 비어 있음)**: 이번에 추가한 정확한 5개만 지운다.
  ```sh
  kubectl -n persona-inference delete networkpolicy \
    default-deny allow-vllm-gateway allow-vllm-metrics allow-vllm-dns allow-model-seed-dns
  ```
- **기존 정책이 있었을 때**: 일괄 삭제(`delete -k`, label selector 삭제)를 하지 않는다. 이번에 새로 생긴
  이름만 지우고, 내용이 바뀐 같은 이름의 정책은 2단계 저장본으로 되돌린다(저장본의
  `resourceVersion`·`uid`·`creationTimestamp`·`managedFields`를 지운 뒤 `kubectl apply -f`).
- **Gateway egress**: Git revert를 머지하고 `persona-app-netpol`을 Sync한다(live patch 금지).
- **지우지 않는 것**: 모델 cache PVC, seed Job, vLLM Deployment·Service, `persona-inference` Namespace.
  정책 롤백에 이 리소스들을 함께 지우지 않는다(`kubectl delete -k`를 model-cache·vllm overlay에 쓰지 않는다).

### 다음 실측 항목 (정책 적용 뒤, 아직 측정하지 않음)

| # | 항목 | 확인 방법 | 기대 |
| --- | --- | --- | --- |
| a | Gateway Pod → vLLM Service 허용 | Gateway Pod에서 `persona-vllm` Service의 `/health` 요청, Hubble `FORWARDED` | 200 |
| b | Prometheus Target UP 유지 | Prometheus `/targets`에서 vLLM PodMonitor Target | `UP` |
| c | 허용되지 않은 일반 Pod → vLLM 차단 | egress 제한이 없는 다른 namespace의 임시 Pod에서 같은 요청, Hubble `Policy denied` | 연결 실패·DROPPED |
| d | 정책 적용 뒤 vLLM 추론 정상 | Gateway Pod에서 짧은 비스트리밍 `/v1/chat/completions` 요청(Gateway LLM mode 전환 없이) | 정상 응답 |

a·b·d는 allow 단계와 deny 단계에서 각각 확인한다. c는 allow 단계에서도 vLLM Ingress가 이미 격리돼
있어 차단돼야 한다. Gateway image에 요청 도구가 없으면 `kubectl debug`의 ephemeral container를 쓴다.
같은 Pod라서 Pod label과 정책 판정이 Gateway와 같다. 요청 본문·응답 원문·토큰은 기록에 남기지 않는다.
상태 코드·지연·Hubble verdict만 적는다.

### 모델 seed 명령과 무결성 기준 (2026-09-27)

- 명령: vLLM image(`vllm/vllm-openai@sha256:51b10427…51b8`, huggingface_hub 1.30.0)에서
  `python3 /opt/persona-seed/seed_model.py`. 스크립트는 ConfigMap으로 싣는다
  (`kustomize/base/persona-model-cache/seed_model.py`). GPU·RuntimeClass를 쓰지 않는다.
- 대상: `Qwen/Qwen3-4B-Instruct-2507` @ `cdbee75f17c01a7cc42f958dc650907174af0554` →
  `/models/Qwen/Qwen3-4B-Instruct-2507/cdbee75f17c01a7cc42f958dc650907174af0554`.
- 완료 판정(종료 코드가 아니라 upstream metadata 대조):
  1. `model_info(files_metadata=True)`의 commit이 고정 revision과 같다.
  2. staging에 받은 파일 목록이 upstream과 정확히 같다(빠진 파일·남는 파일 모두 실패).
  3. 파일마다 크기가 같고, LFS 파일은 sha256, 나머지는 git blob sha1이 같다.
  4. 필수 파일(config·generation_config·tokenizer·tokenizer_config·weight index)이 있고 index가
     가리키는 shard가 모두 있다.
  5. 통과한 경우에만 manifest·완료 marker를 쓰고 최종 경로로 rename한다. 이미 완료된 cache는
     다시 받지 않고 재검증만 하며, 재검증이 실패하면 덮어쓰지 않는다.
- 2026-09-27 upstream metadata 확인: 파일 13개(LFS 4, 일반 9), 약 7.5 GiB, 필수 파일 모두 존재.
  작은 파일 두 개(config.json, generation_config.json)로 git blob sha1 대조가 upstream blob id와
  같음을 확인했다. 전체 다운로드와 실제 Pod 실행은 하지 않았다.

vLLM Deployment보다 정책과 cache seed가 먼저다. cache가 비어 있거나 PodMonitor가 `DOWN`이면
vLLM이 Ready여도 Gateway 설정을 LLM mode로 바꾸지 않는다.

### Gateway LLM 전환 (선언 완료, 적용하지 않음)

`kustomize/base/persona-gateway/deployment.yaml`을 `PERSONA_CHAT_INFERENCE_MODE=llm`,
`PERSONA_VLLM_BASE_URL=http://persona-vllm.persona-inference.svc.cluster.local:8000`,
`PERSONA_VLLM_MODEL=Qwen/Qwen3-4B-Instruct-2507`로 바꾼다. NetworkPolicy·vLLM 설정·모델 PVC는 바꾸지 않는다.

- **이미지와 함께 바꾼다.** vLLM은 `--max-model-len 4096`인데 이전 Gateway 이미지(`sha256:5438d8a8…`)는
  mode와 무관하게 BUDGET_8192로 prompt를 조립한다. 그래서 llm 모드에서 BUDGET_4096을 고르는 이미지
  (persona-gateway PR #21 머지 `16caa0c`, amd64 child `sha256:0ac1ac2a…89ef`)로 image를 함께 바꿨다.
  `validate-persona-app-manifests.sh`가 llm 모드 + 이전 digest 조합을 막는다.
- BUDGET_4096은 글자 수 상한이라 4096 토큰을 보장하지 않는다. 입력 + 출력 512가 넘으면 그 생성은
  `upstream_status_400`으로 실패한다. 자동 재시도하지 않는다.

머지 뒤 실행 순서(사람이 수행, live patch 없음):

1. Argo `persona-app`을 수동 Sync한다.
2. Gateway Pod 2개가 Ready인지 확인한다.
3. 외부 클라이언트에서 Cookie를 준비하고 캐릭터 `setup`을 실행한다(persona-ops-lab SVC-01). 이미
   준비된 캐릭터가 있으면 재사용한다.
4. SVC-01을 `--warmup 1 --rounds 0`으로 실행한다.
5. 그 warmup 샘플이 `mode=llm`, `outcome=success`인지 확인한다.
6. 통과하면 `--warmup 2 --rounds 2`로 질문 8개를 두 번 측정한다.

첫 실행에서 `upstream_status_400`이 나오면 반복 실행하지 말고 길이 초과인지 먼저 확인한다(vLLM 로그의
길이 오류 여부). 이를 피하려고 vLLM 문맥 한도를 바로 늘리지 않는다. 되돌릴 때는 전환 커밋을 revert해
머지하고 `persona-app`을 다시 Sync한다(mock·long profile·이전 image 복원).

## 6. 완료 판정과 미결 값

완료 판정은 다음을 모두 만족하는 것이다.

- PVC가 `persona-gpu-01`에 Bound이고 seed Job이 지정한 model revision을 끝까지 저장했다.
- vLLM Pod가 외부 model egress 없이 local model path에서 Ready가 됐다.
- Gateway와 Prometheus만 vLLM TCP 8000에 성공한다.
- vLLM·DCGM Target이 `UP`이며, 허용하지 않은 namespace/port 흐름은 Hubble에서 차단된다.

seed Job image·명령·model revision은 선언에 고정했다(위 절). Prometheus Pod label은 관측값으로
정했다(2026-09-27). vLLM의 non-root·read-only 기동과 추론, Target `UP`은 운영자 제공 결과로 확인했다.
아직 확정하지 않은 항목은 실제 model FQDN 목록(seed 재실행 전 필요), 정책 적용 뒤 허용·차단 실측
a–d, Gateway 애플리케이션 LLM mode 전환, 성능·과부하 실험이다.
