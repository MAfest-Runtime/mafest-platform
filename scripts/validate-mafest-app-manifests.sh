#!/bin/sh

set -eu

# mafest API·웹(M6 내부 배포) 선언이 문서 35·26D와 이 레포 규칙을 지키는지 로컬에서만 검사한다. 홈 API를 호출하지 않는다.
#
# 워크로드 base(kustomize/base/mafest-app)는 승인된 이미지 digest·설정을 담고, prod overlay가 base를 그대로 연결한다.
# 승인값은 아래 APPROVED_* 상수다. 릴리스를 새로 승인할 때 사람이 선언과 이 상수를 함께 바꾼다(전체 허용으로 풀지 않는다).
#   - base 렌더: 배포될 내용이다. replica·배치·롤링·PDB·probe·보안·Secret·환경변수 값·종료 설정을 본다.
#   - prod 렌더·Argo: base와 같은 내용이 연결되고, 자리표시 digest·UNCONFIRMED 값이 없으며, 활성 Application 두 개가
#     자동 Sync·finalizer 없이 있다. 공개 Route(maintenance-page overlay의 public-maintenance)는 여기서 만들지 않고, 쓰는 ReferenceGrant만 둔다.
#
# 메시지 태그
#   [안전]   어긴 채로 배포하면 데이터·권한 경계가 무너지거나 서비스가 끊긴다.
#   [기준선] 지금 합의한 출발값이다. 실측 뒤 근거를 남기고 바꿀 수 있다.

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/mafest-app.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/base/mafest-app"         > "$work/base.yaml"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/mafest-app" > "$work/prod.yaml"

ruby -ryaml - "$work" "$repo_dir" <<'RUBY'
# encoding: utf-8
#
# 매직 코멘트는 이 heredoc 소스의 인코딩, 아래 대입은 File.read로 읽는 매니페스트의 인코딩을 고정한다.
Encoding.default_external = Encoding::UTF_8

work, repo = ARGV
load_stream = ->(path) { YAML.load_stream(File.read(path)).compact }
base = load_stream.call(File.join(work, "base.yaml"))
prod = load_stream.call(File.join(work, "prod.yaml"))

PLACEHOLDER = /@sha256:0{64}\b/
# 승인된 이미지(feedback 승인 입력). 릴리스마다 사람이 갱신한다.
APPROVED_API_IMAGE = "ghcr.io/persona-runtime/mafest-app@sha256:5f8a8c6f3f46e76f9bc605b62db724c5b6cc0781a7f080cc44daa35513702b8a"
APPROVED_WEB_IMAGE = "ghcr.io/persona-runtime/mafest-web@sha256:f844a216d4ad796df82bf5c5ab82b848262b8af0fe7fc43d946f3c628efb4cb3"
# 이미지 CMD에 --timeout-graceful-shutdown만 더한 승인 실행 형태. 이 외의 args·command는 막는다.
APPROVED_API_ARGS = %w[
  uvicorn mafest.serving.api.app:app --host 0.0.0.0 --port 8000 --workers 1
  --timeout-keep-alive 65 --timeout-graceful-shutdown 100
].freeze
# 종료 유예(초): preStop 10 + graceful 100 + 여유 10. 전체 요청 시한 90초보다 길어야 한다.
APPROVED_GRACE_S = 120
HOME_WORKER_AFFINITY = {
  "requiredDuringSchedulingIgnoredDuringExecution" => {
    "nodeSelectorTerms" => [
      { "matchExpressions" => [{ "key" => "kubernetes.io/hostname", "operator" => "In", "values" => %w[k8s-worker1 k8s-worker2] }] },
    ],
  },
}.freeze

def find(all, kind, name)
  all.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } || raise("missing #{kind}/#{name}")
end

def env_map(container)
  (container["env"] || []).to_h { |e| [e["name"], e] }
end

def check_pod_security(spec, container, context, uid)
  raise "[안전] #{context}: ServiceAccount 토큰을 마운트하지 않는다" unless spec["automountServiceAccountToken"] == false
  raise "[안전] #{context}: seccomp RuntimeDefault가 아니다" unless spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"
  sc = container["securityContext"] || {}
  raise "[안전] #{context}: nonroot(#{uid})로 돌아야 한다" unless sc["runAsNonRoot"] == true && sc["runAsUser"] == uid
  raise "[안전] #{context}: read-only rootfs여야 한다" unless sc["readOnlyRootFilesystem"] == true
  raise "[안전] #{context}: 권한 상승을 막아야 한다" unless sc["allowPrivilegeEscalation"] == false
  raise "[안전] #{context}: capability를 모두 버려야 한다" unless sc.dig("capabilities", "drop") == ["ALL"]
  tmp = (spec["volumes"] || []).find { |v| v["name"] == "tmp" }
  raise "[안전] #{context}: /tmp는 크기를 묶은 emptyDir이어야 한다" unless tmp && tmp.dig("emptyDir", "sizeLimit")
end

def check_pdb(all, name)
  pdb = find(all, "PodDisruptionBudget", name)
  raise "[안전] #{name} PDB는 minAvailable 1이어야 한다(replicas 2와 짝)" unless pdb.dig("spec", "minAvailable") == 1
  raise "[안전] #{name} PDB selector가 자기 Pod 이름 라벨 하나여야 한다" unless pdb.dig("spec", "selector", "matchLabels") == { "app.kubernetes.io/name" => name }
end

raise "[안전] mafest-app base에 Namespace를 넣지 않는다(bootstrap/namespaces가 소유)" if base.any? { |item| item["kind"] == "Namespace" }
raise "[안전] mafest-app base에 NetworkPolicy를 섞지 않는다(networkpolicy/mafest-app이 따로 관리)" if base.any? { |item| item["kind"].to_s.end_with?("NetworkPolicy") }
raise "[안전] mafest-app base에 Secret을 두지 않는다(사람이 Git 밖에서 만든다)" if base.any? { |item| item["kind"] == "Secret" }

# 승인값은 base뿐 아니라 최종 prod 렌더에도 같아야 한다. overlay의 images·patches가 승인 이미지나 설정을 조용히
# 바꿔도 통과하지 않게 같은 검사를 두 렌더에 적용한다.
[["base", base], ["prod", prod]].each do |label, docs|
  # --- API --------------------------------------------------------------------------
  api = find(docs, "Deployment", "mafest-api")
  api_spec = api.dig("spec", "template", "spec")
  raise "[안전] (#{label}) API는 replicas 2다(Pod마다 Uvicorn worker 1)" unless api.dig("spec", "replicas") == 2
  raise "[안전] (#{label}) API 롤링은 maxSurge 1·maxUnavailable 0이다(새 Pod Ready 뒤 교체)" unless api.dig("spec", "strategy", "rollingUpdate") == { "maxSurge" => 1, "maxUnavailable" => 0 }
  raise "[안전] (#{label}) API Pod 라벨 app.kubernetes.io/name=mafest-api는 DB ingress 정책의 계약이다" unless api.dig("spec", "template", "metadata", "labels", "app.kubernetes.io/name") == "mafest-api"
  raise "[안전] (#{label}) API는 두 홈 워커에만 둔다(required nodeAffinity)" unless api_spec.dig("affinity", "nodeAffinity") == HOME_WORKER_AFFINITY
  raise "[안전] (#{label}) API에 required podAntiAffinity를 두지 않는다 — 워커 하나만 남으면 두 번째 Pod가 Pending이다" if api_spec.dig("affinity", "podAntiAffinity", "requiredDuringSchedulingIgnoredDuringExecution")
  spread = api_spec["topologySpreadConstraints"] || []
  raise "[안전] (#{label}) API 분산 제약은 하나여야 한다" unless spread.length == 1
  s = spread.first
  raise "[안전] (#{label}) API 분산: hostname·maxSkew 1·DoNotSchedule·nodeTaintsPolicy Honor여야 한다" unless s["topologyKey"] == "kubernetes.io/hostname" && s["maxSkew"] == 1 && s["whenUnsatisfiable"] == "DoNotSchedule" && s["nodeTaintsPolicy"] == "Honor"
  raise "[안전] (#{label}) API 분산: matchLabelKeys pod-template-hash가 있어야 롤아웃 뒤 새 Pod끼리 나뉜다" unless s["matchLabelKeys"] == ["pod-template-hash"]
  raise "[안전] (#{label}) API 분산: minDomains를 두지 않는다 — 워커 하나만 남으면 두 번째 Pod가 늘 Pending이다" if s.key?("minDomains")
  raise "[안전] (#{label}) API 분산 selector가 API Pod만 골라야 한다" unless s.dig("labelSelector", "matchLabels") == { "app.kubernetes.io/name" => "mafest-api" }
  raise "[안전] (#{label}) API 종료 유예는 #{APPROVED_GRACE_S}초다(preStop 10 + graceful 100 + 여유, 전체 요청 90초보다 길다)" unless api_spec["terminationGracePeriodSeconds"] == APPROVED_GRACE_S
  raise "[안전] (#{label}) API 이미지 pull Secret은 mafest-ghcr다" unless api_spec["imagePullSecrets"] == [{ "name" => "mafest-ghcr" }]

  containers = api_spec["containers"] || []
  raise "[안전] (#{label}) API Pod 컨테이너는 하나다" unless containers.length == 1
  c = containers.first
  raise "[안전] (#{label}) API 이미지는 mafest-app digest 고정이다(태그 금지)" unless c["image"].to_s =~ %r{\Aghcr\.io/persona-runtime/mafest-app@sha256:[0-9a-f]{64}\z}
  raise "[안전] (#{label}) API 이미지가 승인 digest가 아니다(실제 #{c["image"]})" unless c["image"] == APPROVED_API_IMAGE
  raise "[안전] (#{label}) API 컨테이너 포트는 http 8000 하나다(이미지 CMD --port 8000)" unless c["ports"] == [{ "name" => "http", "containerPort" => 8000, "protocol" => "TCP" }]
  raise "[안전] (#{label}) API에 command를 덮어쓰지 않는다 — 승인 args(이미지 CMD + graceful 100초)만 쓴다" if c.key?("command")
  raise "[안전] (#{label}) API args는 승인 실행 형태와 같아야 한다(Uvicorn --workers 1·--timeout-graceful-shutdown 100)" unless c["args"] == APPROVED_API_ARGS
  pre_stop = c.dig("lifecycle", "preStop", "exec", "command")
  raise "[안전] (#{label}) API preStop은 exec sleep 10이어야 한다(엔드포인트 제거 대기)" unless pre_stop == ["sleep", "10"]
  check_pod_security(api_spec, c, "API", 10001)

  env = env_map(c)
  expected_values = {
    "LLM_USE_MOCK" => "0",
    "MAFEST_ENABLE_VECTOR" => "0",
    "MAFEST_LLM_BASE_URL" => "http://persona-vllm.persona-inference.svc.cluster.local:8000",
    "MAFEST_LLM_MODEL" => "Qwen/Qwen3-4B-Instruct-2507",
    "MAFEST_LLM_TIMEOUT_S" => "60",
    "MAFEST_REQUEST_TIMEOUT_S" => "90",
    "MAFEST_READINESS_MODE" => "process",
    "MAFEST_STREAM_PING_S" => "10",
    "MAFEST_DEPENDENCY_CHECK_INTERVAL_S" => "15",
    "MAFEST_DEPENDENCY_CHECK_TIMEOUT_S" => "1",
    "MAFEST_SEARCH_WORKERS" => "8",
    "MAFEST_DB_POOL_MAX" => "4",
    "MAFEST_GRAPH_POOL_MAX" => "2",
    "MAFEST_DATA_BASE_DATE" => "2026-08-21",
    # 멀티턴 확인 질문 초기 활성화(앱 Settings: 정확히 "1"/"0"만 켬/끔). 요약·제안·재시도는 첫 배포에서 끈다.
    "MAFEST_LLM_INTENT" => "1",
    "MAFEST_LLM_STRUCTURED" => "1",
    "MAFEST_LLM_RETRIES" => "0",
    "MAFEST_LLM_SUMMARY" => "0",
    "MAFEST_LLM_SUGGEST" => "0",
    "MAFEST_SESSION_POOL_MAX" => "2",
  }
  expected_values.each do |name, value|
    raise "[안전] (#{label}) API 환경변수 #{name}는 #{value.inspect}여야 한다(실제 #{env.dig(name, "value").inspect})" unless env.dig(name, "value") == value
  end
  # mafest Settings.from_env()가 읽는 이름만 쓴다. 지어낸 이름은 조용히 무시돼 기본값으로 돈다.
  allowed = expected_values.keys + %w[PGURL PGURL_SESSION MAFEST_SESSION_KEY]
  unknown = env.keys - allowed
  raise "[안전] (#{label}) API에 Settings가 읽지 않는 환경변수가 있다: #{unknown.join(", ")}" unless unknown.empty?
  pgurl = env["PGURL"] || raise("[안전] (#{label}) API에 PGURL이 없다")
  raise "[안전] (#{label}) API DSN은 mafest-app Secret mafest-api-db의 PGURL(runtime 계정)이다" unless pgurl.dig("valueFrom", "secretKeyRef") == { "name" => "mafest-api-db", "key" => "PGURL" }
  # 세션 저장소 접속·서버 키: 같은 Secret(mafest-api-session)의 정해진 키만. 두 Pod가 같은 서버 키를 쓰려면 한 Secret이어야 한다.
  { "PGURL_SESSION" => "PGURL_SESSION", "MAFEST_SESSION_KEY" => "MAFEST_SESSION_KEY" }.each do |name, key|
    ref = env[name] || raise("[안전] (#{label}) API에 #{name}이 없다 — 없으면 앱이 기동하지 못한다")
    raise "[안전] (#{label}) #{name}은 mafest-app Secret mafest-api-session의 #{key}다" unless ref.dig("valueFrom", "secretKeyRef") == { "name" => "mafest-api-session", "key" => key }
  end
  # API에는 DDL(owner·마이그레이션) 자격을 넣지 않는다. 세션 마이그레이션 DSN 이름도 API에 두지 않는다.
  raise "[안전] (#{label}) API에 owner용 mafest-migrator를 연결하지 않는다" if YAML.dump(api).include?("mafest-migrator")
  %w[mafest-db-owner PGURL_SESSION_MIGRATE PGURL_SESSION_CLEANUP mafest-session-migrate-db mafest-db-session-migrator mafest_session_migrator].each do |forbidden|
    raise "[안전] (#{label}) API에 #{forbidden}를 연결하지 않는다(DDL·정리 자격은 API 몫이 아니다)" if YAML.dump(api).include?(forbidden)
  end
  # 롤링 중 DB 연결 예산: (replicas + maxSurge) × (검색 풀 + AGE 풀 + 세션 풀). 나머지 절반은 적재 Job·exporter·운영 접속용으로 남긴다.
  cluster_file = File.join(repo, "kustomize/base/mafest-db/cluster.yaml")
  max_connections = YAML.load_stream(File.read(cluster_file)).compact.first.dig("spec", "postgresql", "parameters", "max_connections").to_i
  pods = api.dig("spec", "replicas") + api.dig("spec", "strategy", "rollingUpdate", "maxSurge")
  per_pod = %w[MAFEST_DB_POOL_MAX MAFEST_GRAPH_POOL_MAX MAFEST_SESSION_POOL_MAX].sum { |name| env.dig(name, "value").to_i }
  raise "[안전] (#{label}) 롤링 중 API 연결 #{pods * per_pod}개가 max_connections #{max_connections}의 절반을 넘는다" if max_connections <= 0 || pods * per_pod * 2 > max_connections
  raise "[안전] (#{label}) API에 envFrom을 쓰지 않는다 — 어떤 Secret 키가 들어가는지 선언에서 보이지 않는다" if c.key?("envFrom")

  res = c["resources"] || {}
  raise "[기준선] (#{label}) API 메모리 request 1Gi·limit 1536Mi(문서 35 출발 후보)가 아니다 — 바꿀 때 실측 근거를 남긴다" unless res.dig("requests", "memory") == "1Gi" && res.dig("limits", "memory") == "1536Mi"
  raise "[안전] (#{label}) API에 CPU limit을 두지 않는다(근거 없는 상한은 생성 지연을 키운다)" if res.dig("limits", "cpu")

  probe = ->(name) { c.dig(name, "httpGet", "path") }
  raise "[안전] (#{label}) API startup·liveness는 /healthz다(DB·vLLM 장애로 재시작 루프를 만들지 않는다)" unless probe.call("startupProbe") == "/healthz" && probe.call("livenessProbe") == "/healthz"
  raise "[안전] (#{label}) API readiness는 기본 /readyz다(진단용 deep readiness를 probe에 쓰지 않는다)" unless probe.call("readinessProbe") == "/readyz"
  %w[startupProbe livenessProbe readinessProbe].each do |name|
    raise "[안전] (#{label}) API #{name}는 포트 이름 http를 쓴다" unless c.dig(name, "httpGet", "port") == "http"
  end

  svc = find(docs, "Service", "mafest-api")
  raise "[안전] (#{label}) API Service는 ClusterIP다(NodePort·LoadBalancer 금지)" unless svc.dig("spec", "type") == "ClusterIP"
  raise "[안전] (#{label}) API Service는 8000 → http다" unless svc.dig("spec", "ports") == [{ "name" => "http", "port" => 8000, "targetPort" => "http", "protocol" => "TCP" }]
  check_pdb(docs, "mafest-api")

  pm = find(docs, "PodMonitor", "mafest-api")
  raise "[안전] (#{label}) API PodMonitor는 release: monitoring-stack 라벨이 있어야 수집된다" unless pm.dig("metadata", "labels", "release") == "monitoring-stack"
  raise "[안전] (#{label}) API PodMonitor는 mafest-app의 API Pod만 고른다" unless pm.dig("spec", "namespaceSelector", "matchNames") == ["mafest-app"] && pm.dig("spec", "selector", "matchLabels") == { "app.kubernetes.io/name" => "mafest-api" }
  raise "[안전] (#{label}) API PodMonitor는 http 포트의 /metrics를 긁는다" unless pm.dig("spec", "podMetricsEndpoints", 0, "port") == "http" && pm.dig("spec", "podMetricsEndpoints", 0, "path") == "/metrics"

  # --- 웹 ---------------------------------------------------------------------------
  web = find(docs, "Deployment", "mafest-web")
  web_spec = web.dig("spec", "template", "spec")
  raise "[안전] (#{label}) 웹은 replicas 2다" unless web.dig("spec", "replicas") == 2
  raise "[안전] (#{label}) 웹 롤링은 maxSurge 0·maxUnavailable 1이다(문서 35)" unless web.dig("spec", "strategy", "rollingUpdate") == { "maxSurge" => 0, "maxUnavailable" => 1 }
  raise "[안전] (#{label}) 웹은 두 홈 워커에만 둔다(required nodeAffinity)" unless web_spec.dig("affinity", "nodeAffinity") == HOME_WORKER_AFFINITY
  raise "[안전] (#{label}) 웹 분산은 preferred podAntiAffinity다(required면 워커 하나일 때 재배치가 막힌다)" unless web_spec.dig("affinity", "podAntiAffinity", "preferredDuringSchedulingIgnoredDuringExecution") && !web_spec.dig("affinity", "podAntiAffinity", "requiredDuringSchedulingIgnoredDuringExecution")
  wc = (web_spec["containers"] || []).first || raise("[안전] (#{label}) 웹 컨테이너가 없다")
  raise "[안전] (#{label}) 웹 이미지는 mafest-web digest 고정이다 — persona-web 이미지를 재사용하지 않는다" unless wc["image"].to_s =~ %r{\Aghcr\.io/persona-runtime/mafest-web@sha256:[0-9a-f]{64}\z}
  raise "[안전] (#{label}) 웹 이미지가 승인 digest가 아니다(실제 #{wc["image"]})" unless wc["image"] == APPROVED_WEB_IMAGE
  raise "[안전] (#{label}) 웹 컨테이너 포트는 http 8080 하나다(nginx-unprivileged)" unless wc["ports"] == [{ "name" => "http", "containerPort" => 8080, "protocol" => "TCP" }]
  raise "[안전] (#{label}) 웹에 환경변수·Secret을 넣지 않는다 — API 주소는 빌드 때 상대 /v1로 고정된다" if wc.key?("env") || wc.key?("envFrom")
  check_pod_security(web_spec, wc, "웹", 101)
  web_svc = find(docs, "Service", "mafest-web")
  raise "[안전] (#{label}) 웹 Service는 ClusterIP 8080 → http다" unless web_svc.dig("spec", "type") == "ClusterIP" && web_svc.dig("spec", "ports") == [{ "name" => "http", "port" => 8080, "targetPort" => "http", "protocol" => "TCP" }]
  check_pdb(docs, "mafest-web")
end

# --- prod 렌더·Argo --------------------------------------------------------------
prod_text = YAML.dump(prod)
raise "[안전] mafest-app prod 렌더에 자리표시 digest(0×64)가 있다 — 승인된 digest만 연결한다" if prod_text =~ PLACEHOLDER
raise "[안전] mafest-app prod 렌더에 UNCONFIRMED 값이 있다 — 승인된 기준일을 넣고 연결한다" if prod_text.include?("UNCONFIRMED")
raise "[안전] prod 렌더가 base와 다르다 — overlay는 base를 그대로 연결한다" unless prod.map { |d| [d["kind"], d.dig("metadata", "name")] }.sort == base.map { |d| [d["kind"], d.dig("metadata", "name")] }.sort && !prod.empty?
%w[argocd/mafest-app.yaml argocd/mafest-app-netpol.yaml].each do |path|
  full = File.join(repo, path)
  raise "[안전] #{path}가 없다(활성 Application 두 개가 필요하다)" unless File.exist?(full)
  app = YAML.load_file(full)
  raise "[안전] #{path}: 자동 Sync를 두지 않는다" if app.dig("spec", "syncPolicy")
  raise "[안전] #{path}: finalizer를 두지 않는다" if app.dig("metadata", "finalizers")
  raise "[안전] #{path}: targetRevision은 develop이다" unless app.dig("spec", "source", "targetRevision") == "develop"
  raise "[안전] #{path}: destination namespace는 mafest-app이다" unless app.dig("spec", "destination", "namespace") == "mafest-app"
end

# --- 공개 Route(M8) -------------------------------------------------------------
# 공개 Route는 maintenance-page overlay의 public-maintenance가 맡는다(규칙·Middleware 검사는 validate-public-gateway-
# manifests.sh). 여기서는 mafest-app 쪽 몫만 본다: 옛 초안 경로(mafest-public)를 어디에도 연결하지 않고, 공개 Route가 쓸
# ReferenceGrant가 Service 두 개로 한정돼 mafest-app 렌더에 있다. Route·Middleware를 mafest-app에 섞지 않는다.
raise "[안전] 옛 공개 라우트 초안(kustomize/base/mafest-public)이 남아 있다 — 공개 Route는 maintenance-page overlay 하나다" if File.exist?(File.join(repo, "kustomize/base/mafest-public"))
Dir.glob(File.join(repo, "kustomize/**/kustomization.yaml")).each do |path|
  refs = (YAML.load_file(path) || {}).values_at("resources", "components").flatten.compact
  raise "[안전] #{path.sub(repo + "/", "")}가 옛 공개 라우트 초안 경로(mafest-public)를 연결한다" if refs.any? { |ref| ref.to_s.include?("mafest-public") }
end
Dir.glob(File.join(repo, "argocd/*.yaml")).each do |path|
  raise "[안전] #{path.sub(repo + "/", "")}가 옛 공개 라우트 초안 경로(mafest-public)를 Sync 대상으로 둔다" if YAML.load_file(path).dig("spec", "source", "path").to_s.include?("mafest-public")
end
[["base", base], ["prod", prod]].each do |label, docs|
  raise "[안전] (#{label}) mafest-app에 HTTPRoute·Middleware를 섞지 않는다 — 공개 Route는 persona-app의 maintenance-page가 가진다" if docs.any? { |d| %w[HTTPRoute Middleware].include?(d["kind"]) }
  grants = docs.select { |d| d["kind"] == "ReferenceGrant" }
  raise "[안전] (#{label}) ReferenceGrant는 하나여야 한다" unless grants.length == 1
  grant = grants.first
  raise "[안전] (#{label}) ReferenceGrant는 Service mafest-api·mafest-web 두 개만 허락한다" unless grant.dig("spec", "to") == [{ "group" => "", "kind" => "Service", "name" => "mafest-api" }, { "group" => "", "kind" => "Service", "name" => "mafest-web" }]
  raise "[안전] (#{label}) ReferenceGrant from은 persona-app의 HTTPRoute 하나다" unless grant.dig("spec", "from") == [{ "group" => "gateway.networking.k8s.io", "kind" => "HTTPRoute", "namespace" => "persona-app" }]
end

puts "mafest-app(API·웹 선언 base·prod 렌더·Argo Application·공개 Route용 ReferenceGrant) 검사 통과"
RUBY
