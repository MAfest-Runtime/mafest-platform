#!/bin/sh

set -eu

# NetworkPolicy(persona-app의 준비 중 페이지·persona-edge·traefik·persona-inference·mafest-data·mafest-app) 선언이 합의한
# 계약을 지키는지 로컬에서만 검사한다. 홈 API를 호출하지 않는다.
# scripts/validate-public-gateway-manifests.sh와 같은 패턴([안전] 태그, kubectl kustomize
# 렌더 + ruby 검사)을 쓴다.
#
# persona 앱·DB를 폐기하면서(2026-10-07) persona-app-netpol·persona-db-netpol 검사를 지웠다.
# persona-app namespace에는 준비 중 페이지(maintenance-page overlay)의 정책만 남는다.
#
# 이 스크립트는 "네임스페이스마다 default-deny 정확히 1개 + policyTypes 둘 다"라는
# 안전 하한선과, 문서화한 허용 규칙의 모양(누가 누구에게 어느 포트로)을 확인한다.
# 클러스터가 없으므로 정책이 실제로 반영·시행되는지는 검사 범위 밖이다(런북에 별도 명시).

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
maintenance_file=$(mktemp "${TMPDIR:-/tmp}/maintenance-page.XXXXXX.yaml")
edge_file=$(mktemp "${TMPDIR:-/tmp}/persona-edge.XXXXXX.yaml")
traefik_file=$(mktemp "${TMPDIR:-/tmp}/traefik.XXXXXX.yaml")
inference_file=$(mktemp "${TMPDIR:-/tmp}/persona-inference.XXXXXX.yaml")
mafest_data_file=$(mktemp "${TMPDIR:-/tmp}/mafest-data.XXXXXX.yaml")
mafest_app_file=$(mktemp "${TMPDIR:-/tmp}/mafest-app.XXXXXX.yaml")
trap 'rm -f "$maintenance_file" "$edge_file" "$traefik_file" "$inference_file" "$mafest_data_file" "$mafest_app_file"' EXIT HUP INT TERM

# persona-app namespace 정책은 준비 중 페이지 overlay에 함께 들어 있다(워크로드와 같은 Application).
kubectl kustomize "$repo_dir/kustomize/overlays/prod/maintenance-page"      > "$maintenance_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-edge"            > "$edge_file"
kubectl kustomize "$repo_dir/kustomize/overlays/prod/traefik-networkpolicy"   > "$traefik_file"
# persona-inference는 Argo Application 없이 사람이 kubectl로 적용한다. Argo가 Sync 전에
# 막아 주지 않으므로 적용 전에 이 검사로 렌더와 정책 모양을 확인한다.
kubectl kustomize "$repo_dir/kustomize/overlays/prod/persona-inference-netpol" > "$inference_file"
# mafest-data(CNPG mafest-db) — mafest-db-netpol Application.
kubectl kustomize "$repo_dir/kustomize/overlays/prod/mafest-db-netpol"       > "$mafest_data_file"
# mafest-app(API·웹·적재 Job) — mafest-app-netpol Application(초안). Application이 초안이어도 정책 모양은 지금 검사한다.
kubectl kustomize "$repo_dir/kustomize/overlays/prod/mafest-app-netpol"      > "$mafest_app_file"

ruby -ryaml - "$maintenance_file" "$edge_file" "$traefik_file" "$inference_file" "$mafest_data_file" "$mafest_app_file" "$repo_dir" <<'RUBY'
# encoding: utf-8
#
# heredoc로 넘긴 Ruby 소스는 파일이 아니라 stdin이라, 로케일이 UTF-8이 아니면(LC_ALL=C,
# cron 등) US-ASCII로 파싱돼 아래 한글 메시지에서 "invalid multibyte char"로 즉시 죽는다.
# 아래 Encoding.default_external 대입은 이미 파싱이 끝난 뒤에 실행되므로 그 실패를 막지
# 못한다 — 소스 인코딩을 고정하는 것은 이 매직 코멘트뿐이고, 반드시 첫 줄이어야 한다.
# 두 줄은 서로 다른 문제를 푼다: 매직 코멘트는 이 소스, 아래 대입은 File.read로 읽는
# 외부 매니페스트의 인코딩이다.
Encoding.default_external = Encoding::UTF_8

maintenance_path, edge_path, traefik_path, inference_path, mafest_data_path, mafest_app_path, repo_root = ARGV

def load(path)
  YAML.load_stream(File.read(path)).compact
end

def resources(all, kind, name)
  found = all.select { |item| item["kind"] == kind && item.dig("metadata", "name") == name }
  raise "missing #{kind}/#{name}" if found.empty?
  found
end

def resource(all, kind, name)
  resources(all, kind, name).first
end

def ns(name)
  { "kubernetes.io/metadata.name" => name }
end

# 네임스페이스마다 default-deny가 정확히 1개, podSelector가 전체({}), Ingress·Egress
# 둘 다 policyTypes에 있어야 한다 — 이게 이 검사 전체의 안전 하한선이다. 다른 개별 허용
# 규칙이 틀려도 이 하나가 지켜지면 "뚫린 채로 방치"는 아니다.
def check_default_deny(all, context, name = "default-deny")
  policy = resource(all, "NetworkPolicy", name)
  raise "[안전] #{context} default-deny: podSelector가 네임스페이스 전체(빈 값)가 아니다" unless policy.dig("spec", "podSelector") == {}
  raise "[안전] #{context} default-deny: policyTypes에 Ingress·Egress 둘 다 있어야 한다" unless policy.dig("spec", "policyTypes")&.sort == %w[Egress Ingress]
end

def rule_from_namespaces(rule)
  (rule["from"] || rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") }.compact
end

def rule_ports(rule)
  (rule["ports"] || []).map { |p| [p["protocol"], p["port"]] }
end

# 규칙의 peer가 정확히 하나이고, 그 peer 하나에 namespaceSelector와 podSelector가 **함께**
# 있어야 "이 namespace의 이 Pod"(AND)다. 두 selector를 별도 peer로 나누면 OR가 되어 그
# namespace 전체 또는 정책이 있는 namespace의 같은 라벨 Pod가 허용된다. 그래서 namespace
# 이름·Pod 라벨을 따로 모아 비교하지 않고 peer 전체를 기대값과 통째로 비교한다.
def check_single_and_peer(rule, namespace, pod_labels, context)
  peers = rule["from"] || rule["to"] || []
  expected = { "namespaceSelector" => { "matchLabels" => ns(namespace) }, "podSelector" => { "matchLabels" => pod_labels } }
  raise "[안전] #{context}: peer가 정확히 1개가 아니다(#{peers.length}개) — namespace·Pod selector를 별도 peer로 나누면 OR가 된다" unless peers.length == 1
  raise "[안전] #{context}: #{namespace} namespace AND #{pod_labels} Pod를 같은 peer에서 골라야 한다(실제: #{peers.fetch(0).inspect})" unless peers.fetch(0) == expected
end

# 내부 순서 고정(2026-09-19): allow-*(wave 0) → default-deny(wave 1). 허용 규칙이 먼저
# 들어가야 차단이 걸리는 순간에도 기존 통신이 안 끊긴다. persona-app(준비 중 페이지)·
# persona-inference가 대상이다(persona-edge·traefik은 이번에 안 건드림).
def check_sync_wave(policy, expected, context)
  actual = policy.dig("metadata", "annotations", "argocd.argoproj.io/sync-wave")
  raise "[안전] #{context}: sync-wave가 #{expected}가 아니다(실제: #{actual.inspect})" unless actual == expected
end

# --- persona-app(준비 중 페이지) ---------------------------------------------------
# persona 정리 순서 동안 persona-app-netpol의 default-deny와 같은 이름을 쓰면 두 Application이
# 같은 객체를 추적한다. 그래서 maintenance- 접두사를 쓴다.
maintenance = load(maintenance_path)
check_default_deny(maintenance, "persona-app(maintenance)", "maintenance-default-deny")
check_sync_wave(resource(maintenance, "NetworkPolicy", "maintenance-default-deny"), "1", "persona-app maintenance-default-deny")
page = resource(maintenance, "NetworkPolicy", "maintenance-allow-traefik")
check_sync_wave(page, "0", "persona-app maintenance-allow-traefik")
raise "[안전] maintenance-allow-traefik는 준비 중 페이지 Pod만 골라야 한다" unless page.dig("spec", "podSelector") == { "matchLabels" => { "app.kubernetes.io/name" => "maintenance-page" } }
raise "[안전] maintenance-allow-traefik ingress 규칙이 정확히 1개여야 한다" unless (page.dig("spec", "ingress") || []).length == 1
raise "[안전] 준비 중 페이지는 traefik에서만 인입해야 한다" unless rule_from_namespaces(page.dig("spec", "ingress", 0)) == ["traefik"]
raise "[안전] 준비 중 페이지 인입 포트가 8080이 아니다" unless rule_ports(page.dig("spec", "ingress", 0)) == [["TCP", 8080]]
# 정적 페이지는 밖으로 나갈 일이 없다. egress 허용이 생기면 default-deny의 전면 차단이 풀린다.
maintenance.select { |item| item["kind"] == "NetworkPolicy" }.each do |policy|
  raise "[안전] persona-app #{policy.dig("metadata", "name")}: egress 허용을 두지 않는다" if (policy.dig("spec", "egress") || []).any?
end

# --- persona-edge ----------------------------------------------------------------
edge = load(edge_path)
check_default_deny(edge, "persona-edge")

oauth_in = resource(edge, "NetworkPolicy", "allow-oauth2-proxy-ingress")
raise "[안전] oauth2-proxy는 traefik에서만 인입해야 한다" unless rule_from_namespaces(oauth_in.dig("spec", "ingress", 0)) == ["traefik"]
raise "[안전] oauth2-proxy ingress 포트가 4180이 아니다" unless rule_ports(oauth_in.dig("spec", "ingress", 0)) == [["TCP", 4180]]

# CiliumNetworkPolicy(toFQDNs)만 도메인 이름 기반 egress를 표현할 수 있다 — 표준
# NetworkPolicy는 IP/CIDR만 다룬다(위 network-policy-fqdn.yaml 주석 참고).
oauth_fqdn = resource(edge, "CiliumNetworkPolicy", "allow-oauth2-proxy-fqdn")
oauth_domains = oauth_fqdn.dig("spec", "egress", 0, "toFQDNs").map { |f| f["matchName"] }
raise "[안전] oauth2-proxy FQDN 허용 목록이 다르다(github.com·api.github.com이어야 한다)" unless oauth_domains.sort == %w[api.github.com github.com]

ddns_fqdn = resource(edge, "CiliumNetworkPolicy", "allow-ddns-fqdn")
ddns_domains = ddns_fqdn.dig("spec", "egress", 0, "toFQDNs").map { |f| f["matchName"] }
raise "[안전] ddns FQDN 허용 목록이 다르다(api.cloudflare.com이어야 한다)" unless ddns_domains == ["api.cloudflare.com"]

ddns_ip = resource(edge, "NetworkPolicy", "allow-ddns-egress-public-ip-check")
raise "[안전] ddns 공인 IP 조회 대상이 1.1.1.1/32가 아니다" unless ddns_ip.dig("spec", "egress", 0, "to", 0, "ipBlock", "cidr") == "1.1.1.1/32"

# --- traefik ----------------------------------------------------------------------
traefik = load(traefik_path)
check_default_deny(traefik, "traefik")

world = resource(traefik, "NetworkPolicy", "allow-ingress-world")
raise "[안전] traefik 인입이 0.0.0.0/0(world)이 아니다" unless world.dig("spec", "ingress", 0, "from", 0, "ipBlock", "cidr") == "0.0.0.0/0"
raise "[안전] traefik 인입 포트가 8000·8443이 아니다(entrypoint 실제 포트, Service exposedPort 아님)" unless rule_ports(world.dig("spec", "ingress", 0)).sort == [["TCP", 8000], ["TCP", 8443]]

backend_egress = resource(traefik, "NetworkPolicy", "allow-egress-backends")
backend_targets = backend_egress.dig("spec", "egress").flat_map { |rule| (rule["to"] || []).map { |peer| peer.dig("namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") } }.uniq
raise "[안전] traefik egress 대상이 다르다(persona-app·persona-edge·mafest-app·kube-system이어야 한다)" unless backend_targets.sort == %w[kube-system mafest-app persona-app persona-edge].sort

apiserver = resource(traefik, "CiliumNetworkPolicy", "allow-egress-kube-apiserver")
raise "[안전] traefik의 kube-apiserver egress가 예약 엔티티 kube-apiserver를 쓰지 않는다(하드코딩 IP는 노드 교체 때 끊긴다)" unless apiserver.dig("spec", "egress", 0, "toEntities") == ["kube-apiserver"]
raise "[안전] kube-apiserver egress 포트가 6443이 아니다" unless apiserver.dig("spec", "egress", 0, "toPorts", 0, "ports", 0, "port") == "6443"

# allow-ingress-world(표준 NetworkPolicy, ipBlock 0.0.0.0/0)는 Cilium에서 world
# 아이덴티티만 매칭하고 클러스터 노드 자신에서 나온 트래픽(remote-node·host)은 안
# 걸린다(2026-09-20 실측 — CP curl 000, 맥 302) — 그 경로를 이 CiliumNetworkPolicy가
# 별도로 연다.
cluster_nodes = resource(traefik, "CiliumNetworkPolicy", "allow-ingress-cluster-nodes")
raise "[안전] traefik의 클러스터 노드 인입이 host·remote-node 엔티티를 쓰지 않는다" unless cluster_nodes.dig("spec", "ingress", 0, "fromEntities")&.sort == %w[host remote-node]
# rule_ports는 표준 NetworkPolicy의 flat ingress[].ports[] 모양만 본다 — Cilium은
# ingress[].toPorts[].ports[]로 한 단계 더 감싸고 port 값도 문자열이라(apiserver 검사와
# 같은 이유) 직접 파고든다.
cluster_nodes_ports = (cluster_nodes.dig("spec", "ingress", 0, "toPorts", 0, "ports") || []).map { |p| [p["protocol"], p["port"]] }
raise "[안전] traefik 클러스터 노드 인입 포트가 8000·8443이 아니다" unless cluster_nodes_ports.sort == [["TCP", "8000"], ["TCP", "8443"]]

# monitoring이 PodMonitor로 traefik metrics 포트(9100, Service엔 없고 Pod에만 있다)를
# 직접 스크레이프한다 — persona-data의 monitoring → postgres-exporter:9187과 같은 패턴
# (2026-09-20 실측: 이 허용 없이는 Prometheus 타깃 traefik/traefik이 down).
metrics = resource(traefik, "NetworkPolicy", "allow-ingress-metrics")
raise "[안전] traefik 메트릭 인입이 monitoring에서만 오지 않는다" unless rule_from_namespaces(metrics.dig("spec", "ingress", 0)) == ["monitoring"]
raise "[안전] traefik 메트릭 인입 포트가 9100이 아니다" unless rule_ports(metrics.dig("spec", "ingress", 0)) == [["TCP", 9100]]

# --- mafest-data (CNPG mafest-db) -------------------------------------------------
# 문서 35 §NetworkPolicy: API·loader → 5432, DB 간 복제 5432·8000, operator ↔ instance 8000,
# Prometheus → exporter 9187, DNS, kube-apiserver. allow(wave 0) → default-deny(wave 1).
mafest = load(mafest_data_path)
mafest_db = { "cnpg.io/cluster" => "mafest-db" }
check_default_deny(mafest, "mafest-data", "mafest-default-deny")
check_sync_wave(resource(mafest, "NetworkPolicy", "mafest-default-deny"), "1", "mafest-data mafest-default-deny")
(mafest - [resource(mafest, "NetworkPolicy", "mafest-default-deny")]).each do |policy|
  check_sync_wave(policy, "0", "mafest-data #{policy.dig("metadata", "name")}")
end

db_in = resource(mafest, "NetworkPolicy", "mafest-allow-db-ingress")
raise "[안전] mafest-allow-db-ingress는 mafest-db Pod만 골라야 한다" unless db_in.dig("spec", "podSelector", "matchLabels") == mafest_db
db_in_rules = db_in.dig("spec", "ingress") || []
app_rule = db_in_rules.find { |rule| rule_ports(rule) == [["TCP", 5432]] } || raise("[안전] mafest-db 5432 인입 규칙이 없다")
expected_app_peers = %w[mafest-api mafest-loader].map do |name|
  { "namespaceSelector" => { "matchLabels" => ns("mafest-app") }, "podSelector" => { "matchLabels" => { "app.kubernetes.io/name" => name } } }
end
# namespace·Pod selector를 별도 peer로 나누면 OR가 되어 mafest-app 전체(또는 다른 namespace의 같은 라벨)가 열린다.
raise "[안전] mafest-db 5432는 mafest-app의 mafest-api·mafest-loader Pod(같은 peer의 AND)에서만 와야 한다(실제: #{app_rule["from"].inspect})" unless app_rule["from"] == expected_app_peers
operator_rule = db_in_rules.find { |rule| rule_ports(rule) == [["TCP", 8000]] } || raise("[안전] operator → instance 8000 인입 규칙이 없다")
raise "[안전] 8000 인입은 cnpg-system에서만 와야 한다" unless rule_from_namespaces(operator_rule) == ["cnpg-system"]
metrics_rule = db_in_rules.find { |rule| rule_ports(rule) == [["TCP", 9187]] } || raise("[안전] exporter 9187 인입 규칙이 없다")
check_single_and_peer(metrics_rule, "monitoring",
                      { "app.kubernetes.io/name" => "prometheus", "app.kubernetes.io/instance" => "monitoring-stack-kube-prom-prometheus" },
                      "Prometheus → mafest-db exporter")
raise "[안전] mafest-db 인입 규칙은 5432·8000·9187 세 개다(실제: #{db_in_rules.length}개)" unless db_in_rules.length == 3

db_out = resource(mafest, "NetworkPolicy", "mafest-allow-db-egress")
raise "[안전] mafest-allow-db-egress는 mafest-db Pod만 골라야 한다" unless db_out.dig("spec", "podSelector", "matchLabels") == mafest_db
out_targets = (db_out.dig("spec", "egress") || []).flat_map { |rule| rule_from_namespaces(rule) }.uniq.sort
raise "[안전] mafest-db egress 대상은 kube-system(DNS)·cnpg-system이다(실제: #{out_targets})" unless out_targets == %w[cnpg-system kube-system]

replication = resource(mafest, "NetworkPolicy", "mafest-allow-db-replication")
raise "[안전] 복제 정책은 Ingress·Egress 둘 다다" unless replication.dig("spec", "policyTypes")&.sort == %w[Egress Ingress]
raise "[안전] 복제 ingress는 같은 Cluster Pod에서만 온다" unless replication.dig("spec", "ingress", 0, "from") == [{ "podSelector" => { "matchLabels" => mafest_db } }]
raise "[안전] 복제 egress는 같은 Cluster Pod로만 간다" unless replication.dig("spec", "egress", 0, "to") == [{ "podSelector" => { "matchLabels" => mafest_db } }]
%w[ingress egress].each do |direction|
  raise "[안전] 복제 #{direction} 포트는 5432(WAL)·8000(instance manager)이다" unless rule_ports(replication.dig("spec", direction, 0)).sort == [["TCP", 5432], ["TCP", 8000]]
end

mafest_apiserver = resource(mafest, "CiliumNetworkPolicy", "mafest-allow-egress-kube-apiserver")
raise "[안전] mafest-db kube-apiserver egress endpointSelector가 다르다" unless mafest_apiserver.dig("spec", "endpointSelector", "matchLabels") == mafest_db
raise "[안전] mafest-db kube-apiserver egress는 예약 엔티티 kube-apiserver를 쓴다(IP 하드코딩 금지)" unless mafest_apiserver.dig("spec", "egress", 0, "toEntities") == ["kube-apiserver"]
raise "[안전] mafest-db kube-apiserver egress 포트가 6443이 아니다" unless mafest_apiserver.dig("spec", "egress", 0, "toPorts", 0, "ports", 0, "port") == "6443"
mafest.each do |item|
  (item.dig("spec", "egress") || []).each do |rule|
    raise "[안전] mafest-data egress에 ipBlock을 쓰지 않는다" if (rule["to"] || []).any? { |peer| peer.key?("ipBlock") }
  end
end

# --- persona-inference (수동 적용) --------------------------------------------
# 클러스터 적용 여부와 무관하게 "적용하면 무엇이 열리는가"의 모양을 검사한다.
inference = load(inference_path)
check_default_deny(inference, "persona-inference")
check_sync_wave(resource(inference, "NetworkPolicy", "default-deny"), "1", "persona-inference default-deny")

vllm_label = { "app.kubernetes.io/name" => "persona-vllm" }
seed_label = { "app.kubernetes.io/name" => "persona-vllm-model-seed" }

# 추론 ingress — mafest API Pod 하나만. namespace만 보고 열면 mafest-app의 다른 Pod(웹·
# 적재 Job)도 vLLM에 닿는다.
vllm_ingress = resource(inference, "NetworkPolicy", "allow-vllm-gateway")
check_sync_wave(vllm_ingress, "0", "persona-inference allow-vllm-gateway")
raise "[안전] allow-vllm-gateway는 vLLM Pod만 골라야 한다" unless vllm_ingress.dig("spec", "podSelector", "matchLabels") == vllm_label
raise "[안전] allow-vllm-gateway에 Egress를 열지 않는다(모델 다운로드 경로가 생긴다)" if (vllm_ingress.dig("spec", "policyTypes") || []).include?("Egress")
raise "[안전] allow-vllm-gateway ingress 규칙이 정확히 1개여야 한다" unless (vllm_ingress.dig("spec", "ingress") || []).length == 1
raise "[안전] mafest API → vLLM ingress가 mafest-app에서만 오지 않는다" unless rule_from_namespaces(vllm_ingress.dig("spec", "ingress", 0)) == ["mafest-app"]
check_single_and_peer(vllm_ingress.dig("spec", "ingress", 0), "mafest-app", { "app.kubernetes.io/name" => "mafest-api" }, "mafest API → vLLM ingress")
raise "[안전] vLLM 추론 포트가 TCP 8000이 아니다(CNPG status 8000·Traefik web 8000과 다른 용도다)" unless rule_ports(vllm_ingress.dig("spec", "ingress", 0)) == [["TCP", 8000]]

# metrics는 별도 정책이어야 한다. vLLM은 API와 /metrics를 같은 8000에서 내므로, 포트가
# 같다는 이유로 위 Gateway 허용에 monitoring을 합치면 나중에 그 규칙을 좁힐 때 수집이
# 함께 끊긴다.
vllm_metrics = resource(inference, "NetworkPolicy", "allow-vllm-metrics")
check_sync_wave(vllm_metrics, "0", "persona-inference allow-vllm-metrics")
raise "[안전] allow-vllm-metrics는 vLLM Pod만 골라야 한다" unless vllm_metrics.dig("spec", "podSelector", "matchLabels") == vllm_label
raise "[안전] allow-vllm-metrics에 Egress를 열지 않는다" if (vllm_metrics.dig("spec", "policyTypes") || []).include?("Egress")
raise "[안전] allow-vllm-metrics ingress 규칙이 정확히 1개여야 한다" unless (vllm_metrics.dig("spec", "ingress") || []).length == 1
raise "[안전] vLLM 메트릭 인입이 monitoring에서만 오지 않는다" unless rule_from_namespaces(vllm_metrics.dig("spec", "ingress", 0)) == ["monitoring"]
# 8000은 추론 API와 같은 포트라 monitoring namespace 전체를 열면 Grafana 등도 추론 API에
# 닿는다. kube-prometheus-stack이 Prometheus Pod에 붙이는 두 라벨로 좁힌다.
prometheus_labels = { "app.kubernetes.io/name" => "prometheus", "app.kubernetes.io/instance" => "monitoring-stack-kube-prom-prometheus" }
check_single_and_peer(vllm_metrics.dig("spec", "ingress", 0), "monitoring", prometheus_labels, "Prometheus → vLLM metrics ingress")
raise "[안전] vLLM 메트릭 포트가 TCP 8000이 아니다" unless rule_ports(vllm_metrics.dig("spec", "ingress", 0)) == [["TCP", 8000]]
raise "[안전] 추론 허용과 metrics 허용을 한 정책에 합치지 않는다" if rule_from_namespaces(vllm_ingress.dig("spec", "ingress", 0)).include?("monitoring")

# vLLM 운영 Pod의 egress는 DNS 하나뿐이어야 한다 — 모델은 seed Job이 미리 받아 두고
# 서빙 Pod는 외부로 나갈 이유가 없다.
vllm_dns = resource(inference, "NetworkPolicy", "allow-vllm-dns")
check_sync_wave(vllm_dns, "0", "persona-inference allow-vllm-dns")
raise "[안전] allow-vllm-dns는 vLLM Pod만 골라야 한다" unless vllm_dns.dig("spec", "podSelector", "matchLabels") == vllm_label
raise "[안전] allow-vllm-dns에 Ingress를 섞지 않는다" if (vllm_dns.dig("spec", "policyTypes") || []).include?("Ingress")
vllm_egress_rules = vllm_dns.dig("spec", "egress") || []
raise "[안전] vLLM 운영 Pod의 egress는 DNS 하나여야 한다: #{vllm_egress_rules.length}개" unless vllm_egress_rules.length == 1
raise "[안전] vLLM DNS egress가 kube-system으로 가지 않는다" unless rule_from_namespaces(vllm_egress_rules.fetch(0)) == ["kube-system"]
raise "[안전] vLLM DNS egress 포트가 UDP/TCP 53이 아니다" unless rule_ports(vllm_egress_rules.fetch(0)).sort == [["TCP", 53], ["UDP", 53]]

# seed Job은 vLLM과 다른 label이어야 한다. 같으면 vLLM용 ingress·metrics가 seed Pod에
# 걸리고, seed용 외부 egress가 vLLM에도 열린다.
seed_dns = resource(inference, "NetworkPolicy", "allow-model-seed-dns")
check_sync_wave(seed_dns, "0", "persona-inference allow-model-seed-dns")
raise "[안전] seed Job 정책이 vLLM과 같은 label을 고른다 — 라벨을 분리해야 정책이 섞이지 않는다" unless seed_dns.dig("spec", "podSelector", "matchLabels") == seed_label
raise "[안전] seed DNS egress 포트가 UDP/TCP 53이 아니다" unless rule_ports(seed_dns.dig("spec", "egress", 0)).sort == [["TCP", 53], ["UDP", 53]]

# kubectl apply는 sync-wave를 읽지 않는다. 수동 적용 때 allow를 먼저, default-deny를 마지막에
# 넣을 수 있도록 apply-phase label로 두 묶음을 나눈다. label이 틀리면 `-l ...=allow`로
# default-deny가 함께 들어가거나 allow 정책이 빠진다.
inference.select { |item| item["kind"] == "NetworkPolicy" }.each do |policy|
  name = policy.dig("metadata", "name")
  expected_phase = name == "default-deny" ? "deny" : "allow"
  actual_phase = policy.dig("metadata", "labels", "persona.runtime/apply-phase")
  raise "[안전] persona-inference #{name}: apply-phase label이 #{expected_phase}가 아니다(실제: #{actual_phase.inspect})" unless actual_phase == expected_phase
end

# 표준 NetworkPolicy로는 외부 HTTPS(443)를 열지 않는다. 외부로 나가는 길은 아래 CiliumNetworkPolicy의
# 관측한 FQDN 세 개뿐이다. 누가 ipBlock이나 와일드카드로 443을 열면 여기서 걸린다.
inference.select { |item| item["kind"] == "NetworkPolicy" }.each do |item|
  ports = (item.dig("spec", "egress") || []).flat_map { |rule| rule_ports(rule) }
  raise "[안전] persona-inference에 443 egress가 생겼다 — 모델 호스트는 관측 후 FQDN으로만 연다" if ports.any? { |(_proto, port)| port == 443 || port == "443" }
  (item.dig("spec", "egress") || []).each do |rule|
    raise "[안전] persona-inference egress에 ipBlock을 쓰지 않는다 — namespace·Pod label로만 고른다" if (rule["to"] || []).any? { |peer| peer.key?("ipBlock") }
    # `to`나 `ports`가 비면 "모든 대상" 또는 "모든 포트"라서 위 443 검사를 우회한다.
    raise "[안전] persona-inference egress 규칙에 대상(to)이 없다 — 비우면 world를 포함한 모든 대상이다" if (rule["to"] || []).empty?
    raise "[안전] persona-inference egress 규칙에 포트가 없다 — 비우면 모든 포트다" if (rule["ports"] || []).empty?
  end
end

# seed Job의 상시 FQDN 정책(CiliumNetworkPolicy). 표준 NetworkPolicy와 모양이 달라 따로 본다.
# 허용은 관측한 호스트 matchName과 kube-dns 질의뿐이고, 와일드카드·CIDR·entity는 쓰지 않는다.
SEED_FQDN_HOSTS = %w[cas-server.xethub.hf.co huggingface.co us.aws.cdn.hf.co].freeze
seed_fqdn = inference.find { |item| item["kind"] == "CiliumNetworkPolicy" && item.dig("metadata", "name") == "allow-model-seed-fqdn" }
raise "[안전] persona-inference에 allow-model-seed-fqdn(CiliumNetworkPolicy)이 없다" unless seed_fqdn
check_sync_wave(seed_fqdn, "0", "persona-inference allow-model-seed-fqdn")
raise "[안전] allow-model-seed-fqdn은 seed Pod(persona-vllm-model-seed)만 고른다" unless seed_fqdn.dig("spec", "endpointSelector", "matchLabels") == seed_label
seed_egress = seed_fqdn.dig("spec", "egress") || []
seed_fqdn_rules = seed_egress.select { |rule| rule.key?("toFQDNs") }
raise "[안전] allow-model-seed-fqdn의 toFQDNs 규칙이 정확히 하나여야 한다" unless seed_fqdn_rules.length == 1
seed_hosts = seed_fqdn_rules.first["toFQDNs"]
raise "[안전] allow-model-seed-fqdn toFQDNs에는 matchName만 쓴다(matchPattern·와일드카드 금지): #{seed_hosts.inspect}" unless
  seed_hosts.all? { |entry| entry.keys == ["matchName"] && !entry["matchName"].to_s.include?("*") && !entry["matchName"].to_s.empty? }
raise "[안전] allow-model-seed-fqdn의 호스트는 관측한 세 개여야 한다(실제: #{seed_hosts.map { |e| e['matchName'] }.sort.inspect})" unless
  seed_hosts.map { |entry| entry["matchName"] }.sort == SEED_FQDN_HOSTS
raise "[안전] allow-model-seed-fqdn의 HTTPS 대상은 TCP 443뿐이다" unless
  seed_fqdn_rules.first["toPorts"] == [{ "ports" => [{ "port" => "443", "protocol" => "TCP" }] }]
seed_dns = seed_egress.select { |rule| rule.key?("toEndpoints") }
raise "[안전] allow-model-seed-fqdn의 DNS 규칙이 정확히 하나여야 한다" unless seed_dns.length == 1
raise "[안전] allow-model-seed-fqdn DNS는 kube-system kube-dns 53과 L7 DNS 규칙만 허용한다" unless
  seed_dns.first["toEndpoints"] == [{ "matchLabels" => { "k8s:io.kubernetes.pod.namespace" => "kube-system", "k8s-app" => "kube-dns" } }] &&
  seed_dns.first["toPorts"] == [{ "ports" => [{ "port" => "53", "protocol" => "ANY" }], "rules" => { "dns" => [{ "matchPattern" => "*" }] } }]
raise "[안전] allow-model-seed-fqdn에 toFQDNs·toEndpoints 밖의 egress 대상(toCIDR·toEntities 등)이 있다" unless
  seed_egress.all? { |rule| rule.key?("toFQDNs") || rule.key?("toEndpoints") } &&
  seed_egress.none? { |rule| rule.keys.any? { |key| %w[toCIDR toCIDRSet toEntities toServices toGroups].include?(key) } }

# --- mafest-app(API·웹·적재 Job) --------------------------------------------------
# 순서: allow(wave 0) → default-deny(wave 1). API·적재 Job은 DNS와 정해진 대상만 나가고, 웹은 나가지 않는다.
# 인입은 Traefik(API 8000·웹 8080)과 Prometheus(API 8000, 별도 정책)뿐이다. 상대쪽 짝은 mafest-data의
# mafest-allow-db-ingress와 persona-inference의 allow-vllm-gateway다.
mafest_app = load(mafest_app_path)
check_default_deny(mafest_app, "mafest-app", "mafest-app-default-deny")
check_sync_wave(resource(mafest_app, "NetworkPolicy", "mafest-app-default-deny"), "1", "mafest-app-default-deny")
mafest_app.select { |item| item["kind"] == "NetworkPolicy" }.each do |policy|
  name = policy.dig("metadata", "name")
  raise "[안전] mafest-app 정책 #{name}: 이름은 mafest- 접두사여야 한다" unless name.start_with?("mafest-")
  check_sync_wave(policy, "0", "mafest-app #{name}") unless name == "mafest-app-default-deny"
end
traefik_pod = { "app.kubernetes.io/name" => "traefik" }
api_label = { "app.kubernetes.io/name" => "mafest-api" }
web_label = { "app.kubernetes.io/name" => "mafest-web" }
loader_label = { "app.kubernetes.io/name" => "mafest-loader" }
db_pod = { "cnpg.io/cluster" => "mafest-db" }
dns_pod = { "k8s-app" => "kube-dns" }

api_in = resource(mafest_app, "NetworkPolicy", "mafest-allow-api-ingress")
raise "[안전] mafest-allow-api-ingress는 API Pod만 골라야 한다" unless api_in.dig("spec", "podSelector", "matchLabels") == api_label
raise "[안전] mafest-allow-api-ingress 규칙이 정확히 1개여야 한다" unless (api_in.dig("spec", "ingress") || []).length == 1
check_single_and_peer(api_in.dig("spec", "ingress", 0), "traefik", traefik_pod, "Traefik → mafest API ingress")
raise "[안전] mafest API 인입 포트가 TCP 8000이 아니다" unless rule_ports(api_in.dig("spec", "ingress", 0)) == [["TCP", 8000]]

api_metrics = resource(mafest_app, "NetworkPolicy", "mafest-allow-api-metrics")
raise "[안전] mafest-allow-api-metrics는 API Pod만 골라야 한다" unless api_metrics.dig("spec", "podSelector", "matchLabels") == api_label
raise "[안전] mafest-allow-api-metrics 규칙이 정확히 1개여야 한다" unless (api_metrics.dig("spec", "ingress") || []).length == 1
check_single_and_peer(api_metrics.dig("spec", "ingress", 0), "monitoring", prometheus_labels, "Prometheus → mafest API metrics ingress")
raise "[안전] mafest API 메트릭 포트가 TCP 8000이 아니다" unless rule_ports(api_metrics.dig("spec", "ingress", 0)) == [["TCP", 8000]]

api_out = resource(mafest_app, "NetworkPolicy", "mafest-allow-api-egress")
raise "[안전] mafest-allow-api-egress는 API Pod만 골라야 한다" unless api_out.dig("spec", "podSelector", "matchLabels") == api_label
api_rules = api_out.dig("spec", "egress") || []
raise "[안전] mafest API egress는 DNS·DB·vLLM 세 규칙이어야 한다(실제 #{api_rules.length}개)" unless api_rules.length == 3
check_single_and_peer(api_rules.fetch(0), "kube-system", dns_pod, "mafest API DNS egress")
raise "[안전] mafest API DNS egress 포트가 UDP/TCP 53이 아니다" unless rule_ports(api_rules.fetch(0)).sort == [["TCP", 53], ["UDP", 53]]
check_single_and_peer(api_rules.fetch(1), "mafest-data", db_pod, "mafest API → DB egress")
raise "[안전] mafest API DB egress 포트가 TCP 5432가 아니다" unless rule_ports(api_rules.fetch(1)) == [["TCP", 5432]]
check_single_and_peer(api_rules.fetch(2), "persona-inference", vllm_label, "mafest API → vLLM egress")
raise "[안전] mafest API vLLM egress 포트가 TCP 8000이 아니다" unless rule_ports(api_rules.fetch(2)) == [["TCP", 8000]]

loader_out = resource(mafest_app, "NetworkPolicy", "mafest-allow-loader-egress")
raise "[안전] mafest-allow-loader-egress는 적재 Job Pod만 골라야 한다" unless loader_out.dig("spec", "podSelector", "matchLabels") == loader_label
loader_rules = loader_out.dig("spec", "egress") || []
raise "[안전] 적재 Job egress는 DNS·DB 두 규칙이어야 한다(vLLM·인터넷 없음, 실제 #{loader_rules.length}개)" unless loader_rules.length == 2
check_single_and_peer(loader_rules.fetch(0), "kube-system", dns_pod, "적재 Job DNS egress")
check_single_and_peer(loader_rules.fetch(1), "mafest-data", db_pod, "적재 Job → DB egress")
raise "[안전] 적재 Job DB egress 포트가 TCP 5432가 아니다" unless rule_ports(loader_rules.fetch(1)) == [["TCP", 5432]]

web_in = resource(mafest_app, "NetworkPolicy", "mafest-allow-web-ingress")
raise "[안전] mafest-allow-web-ingress는 웹 Pod만 골라야 한다" unless web_in.dig("spec", "podSelector", "matchLabels") == web_label
check_single_and_peer(web_in.dig("spec", "ingress", 0), "traefik", traefik_pod, "Traefik → mafest 웹 ingress")
raise "[안전] mafest 웹 인입 포트가 TCP 8080이 아니다" unless rule_ports(web_in.dig("spec", "ingress", 0)) == [["TCP", 8080]]

# 웹 egress·mafest-app의 넓은 egress가 생기지 않았는지 본다. 웹은 정적 파일만 내보낸다.
mafest_app.each do |item|
  selected = item.dig("spec", "podSelector", "matchLabels")
  raise "[안전] mafest 웹에 egress 허용을 두지 않는다" if selected == web_label && (item.dig("spec", "egress") || []).any?
  (item.dig("spec", "egress") || []).each do |rule|
    raise "[안전] mafest-app egress에 ipBlock을 쓰지 않는다" if (rule["to"] || []).any? { |peer| peer.key?("ipBlock") }
    raise "[안전] mafest-app egress 규칙에 대상(to)이나 포트가 비어 있다 — 비우면 모든 대상·포트다" if (rule["to"] || []).empty? || (rule["ports"] || []).empty?
  end
end

# --- 모델 seed 관측 정책 (상시 정책이 아니다) -----------------------------------
# allow-model-seed-observe.yaml은 모델 다운로드 호스트를 관측하는 동안만 사람이 `kubectl apply -f`로
# 올린다. 그래서 (1) 어떤 kustomization·Argo 선언에도 들어 있으면 안 되고, (2) 추측한 allowlist가
# 아니도록 HTTPS 대상(toFQDNs)에 와일드카드가 없어야 한다. DNS의 `matchPattern "*"`은 HTTPS를 열지 않고
# 질의 이름을 관측하려는 것이라 허용하는 유일한 와일드카드다.
observe_relative = "kustomize/base/networkpolicy/persona-inference/allow-model-seed-observe.yaml"
observe = YAML.load_file(File.join(repo_root, observe_relative))
raise "[안전] 관측 정책 kind가 CiliumNetworkPolicy가 아니다" unless observe["kind"] == "CiliumNetworkPolicy"
raise "[안전] 관측 정책은 seed Pod(persona-vllm-model-seed)만 고른다" unless
  observe.dig("spec", "endpointSelector", "matchLabels") == { "app.kubernetes.io/name" => "persona-vllm-model-seed" }
observe_egress = observe.dig("spec", "egress") || []
fqdn_rules = observe_egress.select { |rule| rule.key?("toFQDNs") }
raise "[안전] 관측 정책에 toFQDNs 규칙이 정확히 하나여야 한다" unless fqdn_rules.length == 1
names = fqdn_rules.first["toFQDNs"]
raise "[안전] 관측 정책 toFQDNs에는 matchName만 쓴다(matchPattern·와일드카드 금지): #{names.inspect}" unless
  names.all? { |entry| entry.keys == ["matchName"] && !entry["matchName"].to_s.include?("*") && !entry["matchName"].to_s.empty? }
raise "[안전] 관측 정책 HTTPS 대상은 TCP 443뿐이다" unless
  fqdn_rules.first["toPorts"] == [{ "ports" => [{ "port" => "443", "protocol" => "TCP" }] }]
dns_rules = observe_egress.select { |rule| rule.key?("toEndpoints") }
raise "[안전] 관측 정책의 DNS 규칙이 정확히 하나여야 한다" unless dns_rules.length == 1
raise "[안전] 관측 정책 DNS는 kube-system kube-dns 53과 L7 matchPattern \"*\"만 허용한다" unless
  dns_rules.first["toEndpoints"] == [{ "matchLabels" => { "k8s:io.kubernetes.pod.namespace" => "kube-system", "k8s-app" => "kube-dns" } }] &&
  dns_rules.first["toPorts"] == [{ "ports" => [{ "port" => "53", "protocol" => "ANY" }], "rules" => { "dns" => [{ "matchPattern" => "*" }] } }]
raise "[안전] 관측 정책에 toFQDNs·toEndpoints 밖의 egress 대상(toCIDR·toEntities·ipBlock 등)이 있다" unless
  observe_egress.all? { |rule| rule.key?("toFQDNs") || rule.key?("toEndpoints") } &&
  observe_egress.none? { |rule| rule.keys.any? { |key| %w[toCIDR toCIDRSet toEntities toServices toGroups].include?(key) } }
Dir.glob(File.join(repo_root, "{kustomize,argocd}", "**", "*.{yaml,yml}")).sort.each do |path|
  next if path.end_with?("allow-model-seed-observe.yaml")
  raise "[안전] 관측 정책을 다른 선언이 참조한다(상시 적용 금지): #{path.sub(repo_root + '/', '')}" if File.read(path).include?("allow-model-seed-observe")
end

puts "networkpolicy(persona-app 준비 중 페이지·persona-edge·traefik·mafest-data·mafest-app·persona-inference) 렌더와 매니페스트 정책 검사 통과"
RUBY
