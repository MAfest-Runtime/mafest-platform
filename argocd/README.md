# argocd/ — Application 목록

Sync 통제 원칙(`runbooks/public-ingress.md` Gate 3-7 상단, 2026-09-18): "Argo Sync는
'기능 하나 배포'가 아니라 '그 Application이 보는 Git 경로 전체를 반영'이다." 이 표는 각
Application이 정확히 무엇을 반영하는지 이름만으로 헷갈리지 않게 하려는 것이다 — **한
Application = 한 종류의 변경**을 목표로 2026-09-19에 `persona-app`·`persona-db`를 나눴다.

Git source를 쓰는 모든 Application은 `targetRevision: develop`, `syncPolicy.automated` 없음
(자동 Sync·prune 없음, `scripts/validate-*.sh`가 assert)이 원칙이다. Helm chart source는 검토한
chart version을 고정한다. Sync 전에는 `scripts/argo-preflight.sh <app> [--sha <SHA>]`로 승인 SHA·전체 diff·
선행 조건을 확인한다.

## Application

| Application | 경로 | 네임스페이스 | 관리 리소스 종류 | 선행 조건 |
| --- | --- | --- | --- | --- |
| `metallb` | (Helm `metallb/metallb`) | `metallb-system` | MetalLB 컨트롤러·CRD | `bootstrap/namespaces/metallb-system.yaml` 먼저 적용(PSA `privileged`) |
| `metallb-config` | `kustomize/overlays/prod/metallb-config` | `metallb-system` | IPAddressPool·L2Advertisement | `metallb` Sync 먼저(CRD) |
| `cert-manager` | (Helm `jetstack/cert-manager`) | `cert-manager` | cert-manager 컨트롤러·CRD | `bootstrap/namespaces/cert-manager.yaml` 먼저 적용 |
| `cert-manager-issuers` | `kustomize/overlays/prod/cert-manager-issuers` | `cert-manager` | ClusterIssuer(staging·prod) | `cert-manager` Sync 먼저(CRD) |
| `public-gateway` | `kustomize/overlays/prod/public-gateway` | `persona-app` | 공개 진입 Gateway 객체 `persona-app`(http+https listener)만. Certificate·TLS Secret `persona-app-tls`는 cert-manager gateway-shim이 만들며 Git에 선언하지 않음 | 소유권 이관(Phase 1) 완료 상태여야 한다 — live Gateway tracking-id가 `public-gateway`, Certificate 소유자가 현재 Gateway(`scripts/argo-preflight.sh public-gateway`) |
| `maintenance-page` | `kustomize/overlays/prod/maintenance-page` | `persona-app` | 공개(https) HTTPRoute `public-maintenance`(mafest 웹·API로 전환, Middleware `mafest-*`), 내부(http) HTTPRoute `internal-maintenance`, 복구용 정적 준비 중 페이지(nginx Deployment·Service·ConfigMap)와 persona-app NetworkPolicy(`maintenance-` 접두사) | Traefik `kubernetesCRD` 프로바이더, Gateway Programmed, Certificate `persona-app-tls` Ready. **`mafest-app`을 먼저 Sync**(ReferenceGrant). 수동 Sync, 승인 SHA를 정해 `operation.sync.revision`으로 요청한다(M8 런북). 복구는 이전 승인 SHA로 다시 Sync |
| `persona-edge` | `kustomize/overlays/prod/persona-edge` | `persona-edge` | DDNS CronJob + oauth2-proxy + 그 NetworkPolicy(**아직 분리 안 함**) | Secret `oauth2-proxy`·`cloudflare-dns-token` 존재 |
| `mafest-db` | `kustomize/overlays/prod/mafest-db` | `mafest-data` | CNPG Cluster `mafest-db`(PG16+AGE, 2 인스턴스, `Prune=false,Delete=false`)·PodMonitor. Cluster 이미지는 승인 릴리스 digest로 고정돼 렌더에 연결돼 있다 | CNPG operator·CRD, StorageClass local-path, ns `mafest-data`, Secret `mafest-db-owner`·`mafest-db-runtime`·`mafest-ghcr`(이름만), 두 홈 워커 Ready |
| `mafest-db-netpol` | `kustomize/overlays/prod/mafest-db-netpol` | `mafest-data` | NetworkPolicy·CiliumNetworkPolicy만(`mafest-` 접두사, allow wave 0 → default-deny wave 1) | Cluster `mafest-db` healthy, Cilium 상태 ok |
| `monitoring-stack` | (Helm `kube-prometheus-stack`) + `kustomize/overlays/prod/grafana-dashboards`(values ref source의 `path`) | `monitoring` | Prometheus·Grafana, 실험 관측 Grafana 대시보드 ConfigMap 4개 | 없음(유일하게 `syncOptions: [ServerSideApply=true]` — CRD가 커서, `automated`는 아님). 다중 source라 Sync 때 차트는 `89.2.0` 유지·values source만 승인 SHA로 지정한다(`kustomize/base/grafana-dashboards/README.md`) |
| `gpu-runtime` | `kustomize/overlays/prod/gpu-runtime` | `kube-system` | `RuntimeClass/nvidia`만 | `persona-gpu-01` Ready, `node-pool=gpu`, GPU 전용 taint 확인 |
| `dcgm-exporter` | (Helm `dcgm-exporter`) | `monitoring` | GPU 전용 DCGM exporter DaemonSet·Service·ServiceMonitor | `gpu-runtime` Sync 뒤 `RuntimeClass/nvidia` 존재, monitoring Prometheus Available, ServiceMonitor CRD 존재 |
| `nvidia-device-plugin` | `kustomize/overlays/prod/nvidia-device-plugin` | `kube-system` | GPU capacity를 광고하는 NVIDIA device plugin DaemonSet만 | `RuntimeClass/nvidia`, GPU Node Ready, DCGM exporter available=1 |
| `mafest-app-netpol` | `kustomize/overlays/prod/mafest-app-netpol` | `mafest-app` | NetworkPolicy만(`mafest-` 접두사, allow wave 0 → default-deny wave 1): API ← Traefik·Prometheus, API → DNS·DB·vLLM, 적재 Job → DNS·DB, 웹 ← Traefik | **수동 Sync, 승인 SHA 필수**(`scripts/argo-preflight.sh --sha <전체 SHA> mafest-app-netpol` → `argocd app sync --revision <같은 SHA>`). `mafest-app`보다 먼저 Sync한다. 적재 Job이 돌지 않을 때, 짝 정책(Traefik `allow-egress-backends`·persona-inference `allow-vllm-gateway`) 수동 적용 뒤 |
| `mafest-app` | `kustomize/overlays/prod/mafest-app` | `mafest-app` | API·웹 Deployment·Service·PDB, API PodMonitor, 공개 Route용 ReferenceGrant(Service 두 개). base의 승인 digest·설정을 그대로 연결한다 | **수동 Sync, 승인 SHA 필수**(`scripts/argo-preflight.sh --sha <전체 SHA> mafest-app` → `argocd app sync --revision <같은 SHA>`). Secret `mafest-api-db`·`mafest-ghcr`(이름만), `mafest-app-netpol` 먼저. 공개 Route 전환은 `maintenance-page`가 맡는다(여기에 HTTPRoute·Middleware를 두지 않는다) |

## Argo 밖(수동 `kubectl apply -k`/de-registered)

Argo Application이 없는 이유까지 같이 적는다 — "왜 여기 없는가"도 지도의 일부다.

| 경로 | 적용 방식 | 이유 |
| --- | --- | --- |
| `kustomize/overlays/prod/traefik-networkpolicy` | `kubectl apply -k`(CP 수동) | Traefik 본체가 `helm --create-namespace`로 Argo 밖에 설치돼 있어(`bootstrap/traefik/`), 그 NetworkPolicy도 같은 방식으로 다룬다 |
| `kustomize/overlays/prod/traefik-observability` | `kubectl apply -k`(CP 수동) | 위와 같은 이유(Traefik 부속) |
| `kustomize/overlays/prod/mafest-load` | `kubectl apply -k`(CP 수동, runbook 단계마다 한 Job) | 일회성 적재(stage → graph)라 상시 Sync 대상에 두지 않는다. 평상시 `resources: []` |

## dcgm-exporter 수집 지표와 5초 간격 (B0 GPU 계측)

추론 측정 구간마다 GPU 안에서 무엇이 바빴는지 보려고 SM 수준 지표를 더하고 수집 간격을 5초로 줄였다.
`helm/values/dcgm-exporter.yaml`의 `customMetrics`(차트 4.8.4 기본 목록 + 세 줄), `extraEnv`(exporter 간격),
`serviceMonitor.interval/scrapeTimeout`이 한 묶음이다. 지표 뜻은 values 주석에 있다.

- 추가: `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_SM_OCCUPANCY`, `DCGM_FI_DEV_CLOCKS_EVENT_REASONS`.
  이미지 `4.6.1-4.8.4`의 DCGM은 4.6.1(3.3 이상)이라 새 이름을 쓴다. 이전 이름
  `DCGM_FI_DEV_CLOCK_THROTTLE_REASONS`는 같은 필드 번호의 폐기된 별칭이다.
- `customMetrics`는 추가분이 아니라 **전체 목록**이다. 기본 항목을 지우면 지금 쓰는 지표가 사라진다.
- exporter 간격은 명령줄 `-c 5000` 대신 `DCGM_EXPORTER_INTERVAL=5000`(ms)으로 준다. 차트가 인자 값을
  따옴표 없이 렌더해 Kubernetes가 거부한다. `scrapeTimeout`은 `interval`보다 클 수 없어 4s로 낮췄다.
- 시계열 수는 GPU 1장이라 그대로이고 샘플 수만 6배(30s→5s)가 된다.
- 렌더 확인: `sh scripts/validate-gpu-observability-manifests.sh`

적용(수동 Sync, exporter Pod가 재시작되어 그 사이 GPU 지표가 잠시 비고 vLLM 요청에는 영향이 없다):

```bash
scripts/argo-preflight.sh --sha <SHA> dcgm-exporter
argocd app sync dcgm-exporter --revision <SHA>
```

적용 후 확인(context를 명시한다):

```bash
POD=$(kubectl --context <context> -n monitoring get pod -l app.kubernetes.io/name=dcgm-exporter -o jsonpath='{.items[0].metadata.name}')
kubectl --context <context> -n monitoring port-forward pod/$POD 19400:9400 >/dev/null 2>&1 &
sleep 2; curl -s localhost:19400/metrics | grep -oE '^DCGM_FI_[A-Z_]+' | sort -u; kill %1
```

L4에서는 profiling 지표 일부를 동시에 못 모으는 경우가 있다. 지표가 빠지면 exporter 로그의 경고를 본다:

```bash
kubectl --context <context> -n monitoring logs $POD | grep -iE "warn|error|not supported|field"
```

## 신규 Application 추가 시

1. `kustomize/overlays/prod/<name>/`에 그 종류의 리소스만 넣는다(다른 종류를 섞지 않는다).
2. `argocd/<name>.yaml`을 기존 Application 모양으로 만든다. Helm chart와 Git values를 함께
   쓸 때는 `monitoring-stack`처럼 multi-source로 두고, `syncPolicy.automated`를 넣지 않는다.
3. 이 표에 행을 추가한다.
4. `scripts/argo-preflight.sh`의 선행 조건 표에 그 Application의 조건을 추가한다.
5. 관련 `scripts/validate-*.sh`가 새 경로를 렌더·검사하도록 확장한다.
