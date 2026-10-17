#!/bin/sh

set -eu

# mafest 데이터 층(CNPG mafest-db·PodMonitor·적재 Job·Argo Application·namespace·권한 SQL) 선언이 문서 35
# M5·M5b와 이 레포 규칙을 지키는지 로컬에서만 검사한다. 홈 API를 호출하지 않는다.
#
# Cluster(cluster.yaml)는 승인 릴리스 digest로 고정돼 prod 렌더에 연결돼 있고, 적재 Job은 runbook 단계에서만
# 켜므로 평상시 렌더에 없다. 그래서 두 가지를 함께 본다.
#   - 파일 자체: Cluster·Job 파일을 직접 읽어 계약을 검사한다(Job은 켜면 그대로 렌더될 내용이다).
#   - prod 렌더: 자리표시자 digest가 렌더에 없고, Cluster·Job이 렌더에 들어왔다면 실제 digest여야 한다.
#
# 메시지 태그
#   [안전]   어긴 채로 배포하면 데이터 유실·권한 경계 붕괴·연결 끊김이 생긴다.
#   [기준선] 지금 합의한 출발값이다. 실측 뒤 근거를 남기고 바꿀 수 있다.

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/mafest-data.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/overlays/prod/mafest-db"        > "$work/db.yaml"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/mafest-db-netpol" > "$work/netpol.yaml"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/mafest-load"      > "$work/load.yaml"

ruby -ryaml - "$work" "$repo_dir" <<'RUBY'
# encoding: utf-8
#
# 매직 코멘트는 이 heredoc 소스의 인코딩, 아래 대입은 File.read로 읽는 매니페스트의 인코딩을 고정한다.
Encoding.default_external = Encoding::UTF_8

work, repo = ARGV
load_stream = ->(path) { YAML.load_stream(File.read(path)).compact }
db_render = load_stream.call(File.join(work, "db.yaml"))
netpol_render = load_stream.call(File.join(work, "netpol.yaml"))
load_render = load_stream.call(File.join(work, "load.yaml"))

PLACEHOLDER = /@sha256:0{64}\b/
DIGEST = /@sha256:[0-9a-f]{64}\z/
HOME_WORKERS = %w[k8s-worker1 k8s-worker2].freeze
HOME_WORKER_AFFINITY = {
  "requiredDuringSchedulingIgnoredDuringExecution" => {
    "nodeSelectorTerms" => [
      { "matchExpressions" => [{ "key" => "kubernetes.io/hostname", "operator" => "In", "values" => HOME_WORKERS }] },
    ],
  },
}.freeze

base = File.join(repo, "kustomize/base/mafest-db")
draft_path = File.join(base, "cluster.yaml.draft")
live_path = File.join(base, "cluster.yaml")
cluster_path = File.exist?(live_path) ? live_path : draft_path
raise "[안전] mafest-db Cluster 선언(cluster.yaml 또는 cluster.yaml.draft)이 없다" unless File.exist?(cluster_path)
cluster = YAML.load_file(cluster_path)

# --- prod 렌더: 자리표시자·Namespace -------------------------------------------------
[["mafest-db", db_render], ["mafest-db-netpol", netpol_render], ["mafest-load", load_render]].each do |name, render|
  raise "[안전] #{name} 렌더에 Namespace가 있다 — namespace는 bootstrap이 소유한다" if render.any? { |i| i["kind"] == "Namespace" }
  raise "[안전] #{name} 렌더에 자리표시자 digest(0×64)가 있다 — 승인된 릴리스 digest만 연결한다" if YAML.dump(render) =~ PLACEHOLDER
end
rendered_cluster = db_render.find { |i| i["kind"] == "Cluster" }
if rendered_cluster
  raise "[안전] Cluster가 렌더에 연결됐는데 이미지가 digest 고정이 아니다" unless rendered_cluster.dig("spec", "imageName").to_s =~ DIGEST
end
db_render.each do |item|
  raise "[안전] mafest-db 리소스는 mafest-data namespace여야 한다: #{item["kind"]}/#{item.dig("metadata", "name")}" unless item.dig("metadata", "namespace") == "mafest-data"
end

# --- Cluster(파일) -----------------------------------------------------------------------
spec = cluster.fetch("spec")
raise "[안전] Cluster kind가 아니다" unless cluster["kind"] == "Cluster" && cluster["apiVersion"] == "postgresql.cnpg.io/v1"
raise "[안전] Cluster 이름은 mafest-db다(NetworkPolicy·PodMonitor selector가 cnpg.io/cluster: mafest-db를 본다)" unless cluster.dig("metadata", "name") == "mafest-db"
sync_options = cluster.dig("metadata", "annotations", "argocd.argoproj.io/sync-options").to_s.split(",").map(&:strip)
raise "[안전] Cluster에 Prune=false·Delete=false가 둘 다 있어야 한다 — Argo가 DB를 지우면 안 된다" unless (%w[Prune=false Delete=false] - sync_options).empty?
raise "[안전] instances는 2다(문서 35 M5 DB 2/2)" unless spec["instances"] == 2
raise "[안전] postgres superuser 계정을 활성화하지 않는다" unless spec["enableSuperuserAccess"] == false
image = spec["imageName"].to_s
raise "[안전] Cluster 이미지는 mafest-postgres:<태그>@sha256:<digest>여야 한다(태그로 major 버전, digest로 객체 고정)" unless image =~ %r{\Aghcr\.io/persona-runtime/mafest-postgres:16\.[^@]+@sha256:[0-9a-f]{64}\z}
raise "[안전] Cluster imagePullSecrets는 mafest-ghcr 하나다" unless spec["imagePullSecrets"] == [{ "name" => "mafest-ghcr" }]

affinity = spec.fetch("affinity")
raise "[안전] 두 인스턴스를 다른 워커에 두려면 enablePodAntiAffinity가 켜져 있어야 한다" unless affinity["enablePodAntiAffinity"] == true
raise "[안전] anti-affinity는 required다 — preferred면 자원이 빠듯할 때 한 워커에 몰린다" unless affinity["podAntiAffinityType"] == "required"
raise "[안전] anti-affinity topologyKey는 kubernetes.io/hostname이다" unless affinity["topologyKey"] == "kubernetes.io/hostname"
raise "[안전] nodeSelector를 쓰지 않는다 — 두 워커 nodeAffinity로만 고른다" if affinity.key?("nodeSelector")
raise "[안전] DB는 두 홈 워커(k8s-worker1, k8s-worker2)만 노드 후보다(CP·GPU 노드 제외)" unless affinity["nodeAffinity"] == HOME_WORKER_AFFINITY

postgresql = spec.fetch("postgresql")
raise "[안전] shared_preload_libraries에 age가 있어야 한다 — runtime 계정은 LOAD 'age'를 못 한다" unless Array(postgresql["shared_preload_libraries"]).include?("age")
params = postgresql.fetch("parameters")
raise "[안전] shared_preload_libraries는 parameters가 아니라 spec.postgresql.shared_preload_libraries로 둔다" if params.key?("shared_preload_libraries")
raise "[기준선] jit은 off다(문서 35 M5)" unless params["jit"] == "off"

initdb = spec.dig("bootstrap", "initdb") || {}
raise "[안전] initdb database·owner·secret이 문서 11 규약(mafest·mafest_owner·mafest-db-owner)과 다르다" unless
  initdb["database"] == "mafest" && initdb["owner"] == "mafest_owner" && initdb["secret"] == { "name" => "mafest-db-owner" }
raise "[안전] locale은 C(정렬)·C.UTF-8(문자 분류)다 — 적재 첫 단계 locale 검사가 C.UTF-8을 요구한다" unless
  initdb["localeCollate"] == "C" && initdb["localeCType"] == "C.UTF-8"
post_init = Array(initdb["postInitApplicationSQL"]).join("\n")
%w[age pg_trgm].each do |extension|
  raise "[안전] initdb에서 #{extension} 확장을 만들어야 한다 — 확장 생성은 superuser 몫이다" unless post_init =~ /CREATE EXTENSION IF NOT EXISTS #{extension}\b/i
end
runtime_role = (spec.dig("managed", "roles") || []).find { |r| r["name"] == "mafest_runtime" }
raise "[안전] mafest_runtime은 managed.roles로 만든다(비밀번호는 Secret mafest-db-runtime)" unless runtime_role &&
  runtime_role["login"] == true && runtime_role.dig("passwordSecret", "name") == "mafest-db-runtime"
%w[superuser createdb createrole replication bypassrls].each do |flag|
  raise "[안전] mafest_runtime에 #{flag}를 주지 않는다" if runtime_role[flag] == true
end
# 세션 저장소 API 역할: 검색 runtime과 별도 역할·별도 Secret이고 특권이 없다(권한은 마이그레이션 CLI의 APP_GRANTS).
session_role = (spec.dig("managed", "roles") || []).find { |r| r["name"] == "mafest_session" }
raise "[안전] mafest_session은 managed.roles로 만든다(비밀번호는 Secret mafest-db-session)" unless session_role &&
  session_role["login"] == true && session_role.dig("passwordSecret", "name") == "mafest-db-session"
%w[superuser createdb createrole replication bypassrls].each do |flag|
  raise "[안전] mafest_session에 #{flag}를 주지 않는다" if session_role[flag] == true
end
raise "[안전] 세션 역할과 검색 runtime은 같은 Secret을 쓰지 않는다" if
  session_role.dig("passwordSecret", "name") == runtime_role.dig("passwordSecret", "name")
# 세션 스키마 마이그레이션(DDL) 역할: 상품 owner(mafest_owner)가 아니다. owner 의 전역 기본 권한이 새 세션 테이블을
# 검색 계정에 열어 주기 때문이다. 별도 역할·별도 Secret이고 특권이 없다.
migrator_role = (spec.dig("managed", "roles") || []).find { |r| r["name"] == "mafest_session_migrator" }
raise "[안전] mafest_session_migrator는 managed.roles로 만든다(비밀번호는 Secret mafest-db-session-migrator)" unless migrator_role &&
  migrator_role["login"] == true && migrator_role.dig("passwordSecret", "name") == "mafest-db-session-migrator"
%w[superuser createdb createrole replication bypassrls].each do |flag|
  raise "[안전] mafest_session_migrator에 #{flag}를 주지 않는다" if migrator_role[flag] == true
end
role_secrets = (spec.dig("managed", "roles") || []).map { |r| r.dig("passwordSecret", "name") }
raise "[안전] managed 역할의 비밀번호 Secret 이름이 서로 달라야 한다(검색·세션·마이그레이션 자격을 섞지 않는다)" unless role_secrets.uniq.length == role_secrets.length

storage = spec.fetch("storage")
raise "[안전] storageClass는 local-path다" unless storage["storageClass"] == "local-path"
raise "[기준선] storage size가 기준선(10Gi, 문서 11)과 다르다 — local-path는 나중에 못 늘린다" unless storage["size"] == "10Gi"
resources = spec.fetch("resources")
raise "[기준선] DB 메모리 requests·limits가 기준선(1Gi, 문서 35 출발 후보)과 다르다" unless
  resources.dig("requests", "memory") == "1Gi" && resources.dig("limits", "memory") == "1Gi"
raise "[기준선] DB에 CPU limit을 두지 않는다 — throttling이 곧 질의 지연이 된다" if resources.dig("limits", "cpu")
raise "[기준선] 커스텀 PriorityClass는 보류한다" unless spec["priorityClassName"].to_s.empty?
raise "[안전] CNPG enablePodMonitor(1.30 deprecated)를 켜지 않는다 — 독립 PodMonitor와 중복된다" if spec.dig("monitoring", "enablePodMonitor")

# --- PodMonitor(렌더) ----------------------------------------------------------------------
monitors = db_render.select { |i| i["kind"] == "PodMonitor" }
raise "[안전] mafest-db PodMonitor가 정확히 1개여야 한다: #{monitors.length}개" unless monitors.length == 1
monitor = monitors.first
raise "[안전] PodMonitor에 release=monitoring-stack 라벨이 있어야 Prometheus가 대상으로 잡는다" unless monitor.dig("metadata", "labels", "release") == "monitoring-stack"
raise "[안전] PodMonitor namespaceSelector는 mafest-data만이다" unless monitor.dig("spec", "namespaceSelector", "matchNames") == ["mafest-data"]
raise "[안전] PodMonitor selector는 cnpg.io/cluster: mafest-db 하나다" unless monitor.dig("spec", "selector") == { "matchLabels" => { "cnpg.io/cluster" => "mafest-db" } }
endpoints = monitor.dig("spec", "podMetricsEndpoints") || []
raise "[안전] PodMonitor endpoint는 metrics 포트 /metrics 하나다" unless endpoints.length == 1 && endpoints[0]["port"] == "metrics" && endpoints[0]["path"] == "/metrics"

# --- NetworkPolicy(렌더) — 모양은 validate-networkpolicy-manifests.sh가 자세히 본다 -------------
deny = netpol_render.find { |i| i["kind"] == "NetworkPolicy" && i.dig("metadata", "name") == "mafest-default-deny" }
raise "[안전] mafest-data에 mafest-default-deny가 있어야 한다" unless deny
allows = netpol_render.reject { |i| i.equal?(deny) }
raise "[안전] default-deny만 있고 allow가 없으면 DB 복제·operator 상태 조회가 끊긴다" if allows.empty?
netpol_render.each do |policy|
  name = policy.dig("metadata", "name").to_s
  raise "[안전] mafest-data 정책 이름은 mafest- 접두사다: #{name}" unless name.start_with?("mafest-")
end

# --- 적재 Job(파일) -----------------------------------------------------------------------
load_base = File.join(repo, "kustomize/base/mafest-load")
load_kustomization = YAML.load_file(File.join(load_base, "kustomization.yaml"))
active = Array(load_kustomization["resources"])
raise "[안전] 적재 Job은 한 번에 하나만 켠다(stage → graph 순서, 동시 실행 금지): #{active}" if active.length > 1
JOB_LIMITS = { "stage" => "512Mi", "graph" => "256Mi" }.freeze
JOB_LIMITS.each do |step, memory|
  path = File.join(load_base, "job-#{step}.yaml")
  raise "[안전] 적재 Job 파일이 없다: job-#{step}.yaml" unless File.exist?(path)
  job = YAML.load_file(path)
  context = "mafest-load-#{step}"
  raise "[안전] #{context}: backoffLimit 0이어야 한다 — 실패한 적재를 자동으로 다시 돌리지 않는다" unless job.dig("spec", "backoffLimit") == 0
  raise "[안전] #{context}: activeDeadlineSeconds가 없다 — 멈춘 적재가 무한히 남는다" unless job.dig("spec", "activeDeadlineSeconds").to_i.positive?
  pod = job.dig("spec", "template", "spec")
  raise "[안전] #{context}: restartPolicy는 Never다" unless pod["restartPolicy"] == "Never"
  raise "[안전] #{context}: ServiceAccount 토큰을 마운트하지 않는다" unless pod["automountServiceAccountToken"] == false
  raise "[안전] #{context}: Pod는 root가 아닌 사용자로 돈다" unless pod.dig("securityContext", "runAsNonRoot") == true
  raise "[안전] #{context}: 홈 워커에서만 돈다(CP·GPU 제외)" unless pod.dig("affinity", "nodeAffinity") == HOME_WORKER_AFFINITY
  raise "[안전] #{context}: imagePullSecrets는 mafest-ghcr 하나다" unless pod["imagePullSecrets"] == [{ "name" => "mafest-ghcr" }]
  label = job.dig("spec", "template", "metadata", "labels", "app.kubernetes.io/name")
  raise "[안전] #{context}: Pod 라벨이 mafest-loader가 아니면 DB NetworkPolicy 5432 허용에 걸리지 않는다" unless label == "mafest-loader"
  containers = pod.fetch("containers")
  raise "[안전] #{context}: 컨테이너는 하나다" unless containers.length == 1
  c = containers.first
  raise "[안전] #{context}: 이미지는 mafest-app digest 고정이다(태그 금지)" unless c["image"].to_s =~ %r{\Aghcr\.io/persona-runtime/mafest-app@sha256:[0-9a-f]{64}\z}
  raise "[안전] #{context}: command는 python -m mafest.deploy.load --step #{step}이다" unless c["command"] == ["python", "-m", "mafest.deploy.load", "--step", step]
  sc = c["securityContext"] || {}
  raise "[안전] #{context}: 루트 파일시스템은 읽기 전용이다" unless sc["readOnlyRootFilesystem"] == true
  raise "[안전] #{context}: 권한 상승을 막는다" unless sc["allowPrivilegeEscalation"] == false
  raise "[안전] #{context}: capability는 모두 버린다" unless sc.dig("capabilities", "drop") == ["ALL"]
  raise "[기준선] #{context}: 메모리 limit이 기준선(#{memory}, M1 peak ×1.3)과 다르다" unless c.dig("resources", "limits", "memory") == memory
  env = c["env"] || []
  pgurl = env.find { |e| e["name"] == "PGURL" }
  raise "[안전] #{context}: PGURL은 Secret mafest-migrator(키 PGURL) 참조만 쓴다 — 평문 value 금지" unless
    pgurl && !pgurl.key?("value") && pgurl.dig("valueFrom", "secretKeyRef") == { "name" => "mafest-migrator", "key" => "PGURL" }
  env.each do |e|
    raise "[안전] #{context}: env #{e["name"]}에 DSN·비밀 모양 값을 평문으로 두지 않는다" if e["value"].to_s =~ %r{postgres(ql)?://|password}i
  end
  tmp_mount = (c["volumeMounts"] || []).find { |m| m["mountPath"] == "/tmp" }
  raise "[안전] #{context}: /tmp를 emptyDir로 마운트해야 한다(읽기 전용 루트에서 적재 임시 파일)" unless tmp_mount
  tmp_volume = (pod["volumes"] || []).find { |v| v["name"] == tmp_mount["name"] }
  size = tmp_volume&.dig("emptyDir", "sizeLimit").to_s
  mib = size.end_with?("Gi") ? size.to_f * 1024 : size.to_f
  raise "[기준선] #{context}: /tmp emptyDir sizeLimit은 256Mi 이상이다(M1 권장)" unless tmp_volume&.key?("emptyDir") && mib >= 256
end

# --- Argo Application ------------------------------------------------------------------------
{
  "mafest-db" => "kustomize/overlays/prod/mafest-db",
  "mafest-db-netpol" => "kustomize/overlays/prod/mafest-db-netpol",
}.each do |name, source_path|
  path = File.join(repo, "argocd", "#{name}.yaml")
  raise "[안전] #{name} Application 선언이 없다" unless File.exist?(path)
  app = YAML.load_file(path)
  raise "[안전] #{name}: Application kind·이름이 다르다" unless app["kind"] == "Application" && app.dig("metadata", "name") == name
  app_spec = app.fetch("spec")
  raise "[안전] #{name}: develop 브랜치를 봐야 한다" unless app_spec.dig("source", "targetRevision") == "develop"
  raise "[안전] #{name}: source path가 다르다" unless app_spec.dig("source", "path") == source_path
  raise "[안전] #{name}: 대상 namespace는 mafest-data다" unless app_spec.dig("destination", "namespace") == "mafest-data"
  raise "[안전] #{name}: 자동 Sync를 켜면 안 된다(syncPolicy 금지)" if app_spec.key?("syncPolicy")
  raise "[안전] #{name}: finalizers를 두지 않는다 — Application 삭제가 DB 삭제로 번진다" unless app.dig("metadata", "finalizers").nil?
end
raise "[안전] 적재 Job은 Argo 밖에서 사람이 실행한다 — mafest-load Application을 두지 않는다" if
  Dir.glob(File.join(repo, "argocd", "*.yaml")).any? { |f| File.read(f).include?("overlays/prod/mafest-load") }

# --- bootstrap namespace ---------------------------------------------------------------------
{ "mafest-data" => "data", "mafest-app" => "application" }.each do |name, component|
  ns = YAML.load_file(File.join(repo, "bootstrap/namespaces/#{name}.yaml"))
  raise "[안전] bootstrap #{name} Namespace 선언이 다르다" unless ns["kind"] == "Namespace" && ns.dig("metadata", "name") == name &&
    ns.dig("metadata", "labels", "app.kubernetes.io/component") == component
end

# --- 권한 SQL 계약 ---------------------------------------------------------------------------
# 주석에는 "이렇게 하지 않는다"는 설명이 있으므로 실제 문장만 본다.
sql = lambda do |name|
  File.read(File.join(repo, "db/grants", name)).lines.map { |line| line.sub(/--.*$/, "") }.join
end
roles = sql.call("mafest_roles.sql")
post_load = sql.call("mafest_post_load.sql")
check = sql.call("mafest_runtime_check.sql")
[roles, post_load].each do |text|
  raise "[안전] runtime에 쓰기 권한(INSERT·UPDATE·DELETE·TRUNCATE·CREATE·ALL)을 주지 않는다" if
    text =~ /GRANT\s+[^;]*\b(INSERT|UPDATE|DELETE|TRUNCATE|ALL\s+PRIVILEGES|CREATE)\b[^;]*TO\s+[^;]*mafest_runtime/im
  raise "[안전] 비밀번호를 SQL에 두지 않는다(managed.roles·Secret 사용)" if text =~ /\bPASSWORD\b/i
end
raise "[안전] cnpg_metrics_exporter CONNECT를 유지해야 한다 — 빠지면 지표 수집이 끊긴다" unless roles =~ /GRANT CONNECT ON DATABASE mafest TO [^;]*cnpg_metrics_exporter/i
raise "[안전] mafest_session은 DB CONNECT만 SQL로 받는다(테이블 권한은 마이그레이션 CLI)" unless roles =~ /GRANT CONNECT ON DATABASE mafest TO mafest_session\s*;/i
[roles, post_load].each do |text|
  raise "[안전] mafest_session에 SQL로 테이블·스키마 권한을 주지 않는다(마이그레이션 CLI --app-role 몫)" if
    text =~ /GRANT\s+(?!CONNECT\b)[^;]*\bTO\s+[^;]*mafest_session/im
end
raise "[안전] mafest_session_migrator는 DB CONNECT·CREATE만 SQL로 받는다" unless roles =~ /GRANT CONNECT, CREATE ON DATABASE mafest TO mafest_session_migrator\s*;/i
raise "[안전] mafest_session_migrator를 대상으로 한 ALTER DEFAULT PRIVILEGES를 두지 않는다(새 세션 테이블이 다른 역할에 열린다)" if
  [roles, post_load].any? { |text| text =~ /ALTER\s+DEFAULT\s+PRIVILEGES\s+FOR\s+ROLE\s+mafest_session_migrator/i }
raise "[안전] 세션 테이블이 검색 계정에 열리지 않게 mafest_owner 기본 권한 줄은 그대로 두고 owner 로 세션 스키마를 만들지 않는다" if
  roles =~ /CREATE\s+SCHEMA\s+[^;]*mafest_confirm/i || post_load =~ /mafest_confirm/i
# 세션 스키마 사전 점검·유효 권한 검사 SQL: 읽기 전용(BEGIN READ ONLY … ROLLBACK)이며 변경문이 없다.
{
  "mafest_session_precheck.sql" => %w[mafest_runtime aclexplode],
  "mafest_session_check.sql" => %w[owner-schema owner-objects session-usage session-allow session-deny session-ddl isolated-schema isolated-table public-acl role-membership default-acl mafest_runtime aclexplode pg_has_role pg_default_acl],
}.each do |name, required|
  text = sql.call(name)
  raise "[안전] #{name}은 BEGIN READ ONLY와 ROLLBACK으로 감싸야 한다" unless text =~ /\bBEGIN\s+READ\s+ONLY\s*;/i && text =~ /\bROLLBACK\s*;/i
  bare = text.gsub(/'[^']*'/, "''") # 문자열 안의 권한 이름(CREATE 등)은 변경문이 아니다
  raise "[안전] #{name}에 변경문(ALTER·DROP·GRANT·REVOKE·INSERT·UPDATE·DELETE·TRUNCATE·CREATE)이 있다 — 읽기 전용이어야 한다" if
    bare =~ /\b(ALTER|DROP|GRANT|REVOKE|INSERT|UPDATE|DELETE|TRUNCATE|CREATE)\b/i
  required.each do |item|
    raise "[안전] #{name}에 #{item} 검사가 없다" unless text.include?(item)
  end
end
raise "[안전] PUBLIC의 DB 기본 권한을 걷어야 한다" unless roles =~ /REVOKE ALL ON DATABASE mafest FROM PUBLIC/i
raise "[안전] 두 역할에 ag_catalog USAGE가 필요하다" unless roles =~ /GRANT USAGE ON SCHEMA ag_catalog TO mafest_owner, mafest_runtime/i
raise "[안전] runtime search_path는 ag_catalog, \"$user\", public이다(preload 전제)" unless roles =~ /ALTER ROLE mafest_runtime SET search_path = ag_catalog, "\$user", public/i
raise "[안전] 기본 권한은 실제 owner(mafest_owner)로 한정한다" unless roles =~ /ALTER DEFAULT PRIVILEGES FOR ROLE mafest_owner GRANT SELECT ON TABLES TO mafest_runtime/i
raise "[안전] runtime 확인 SQL은 쓰기 시도를 ROLLBACK으로 감싸야 한다" unless check =~ /\bBEGIN;/ && check =~ /\bROLLBACK;/
%w[write-insert write-create write-cypher write-graph].each do |name|
  raise "[안전] runtime 확인 SQL에 #{name} 거부 검사가 없다" unless check.include?(name)
end

puts "mafest 데이터 층(DB Cluster·PodMonitor·NetworkPolicy 이름·적재 Job·Application·namespace·권한 SQL) 검사 통과"
RUBY
