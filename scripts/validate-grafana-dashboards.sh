#!/bin/sh

set -eu

# 실험 관측 Grafana 대시보드 배포 사본(kustomize/base/grafana-dashboards)과 monitoring-stack 연결을
# 로컬에서만 검사한다. 클러스터를 호출하지 않고 Argo Sync도 하지 않는다.
#
# JSON 정본은 persona-ops-lab(dashboards/)이고 여기는 `scripts/check_dashboards.py --export`로 만든 사본이다.
# SOURCE.sha256(정본 해시)과 사본이 같고, 렌더한 ConfigMap 내용이 사본과 같은지 본다. 정본의 지표 이름·원본
# 출처 검사는 ops-lab 쪽 몫이다 — 여기서는 자동 로딩이 깨지지 않는 모양(UID·패널 ID·datasource·__inputs·크기·
# 라벨)과 Argo 연결(차트 revision·values·수동 Sync 보존)을 본다.
#
# 렌더 검사 통과는 Grafana 로딩이나 쿼리 결과의 증거가 아니다(배포 후 확인).
#
# 메시지 태그
#   [안전]   어긴 채로 배포하면 대시보드가 로드되지 않거나 기존 모니터링 설정이 바뀐다.
#   [기준선] 지금 합의한 값이다.

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
rendered=$(mktemp "${TMPDIR:-/tmp}/grafana-dashboards.XXXXXX.yaml")
trap 'rm -f "$rendered"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/overlays/prod/grafana-dashboards" > "$rendered"

ruby -ryaml -rjson -rdigest - "$rendered" "$repo_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8

rendered_path, repo = ARGV
base = File.join(repo, "kustomize/base/grafana-dashboards")
docs = YAML.load_stream(File.read(rendered_path)).compact

DASHBOARDS = {
  "vllm-serving" => "persona-vllm",
  "gpu-dcgm" => "persona-gpu",
  "postgres-cnpg" => "persona-cnpg",
  "mafest-service" => "persona-mafest",
}.freeze
CONFIGMAP_LIMIT = 900_000 # 1MiB 한도에서 여유를 둔다
ALLOWED_DATASOURCES = [
  { "type" => "prometheus", "uid" => "prometheus" },
  { "type" => "__expr__", "uid" => "__expr__" },
  { "type" => "grafana", "uid" => "-- Grafana --" },
  { "type" => "datasource", "uid" => "grafana" },
].freeze

def each_datasource(node, &block)
  case node
  when Hash then node.each { |k, v| k == "datasource" ? block.call(v) : each_datasource(v, &block) }
  when Array then node.each { |v| each_datasource(v, &block) }
  end
end

def each_panel(panels, &block)
  panels.each do |panel|
    block.call(panel)
    each_panel(panel["panels"] || [], &block)
  end
end

# --- 렌더한 ConfigMap ----------------------------------------------------------
raise "[안전] 렌더에 ConfigMap 외 리소스가 있다: #{docs.map { |d| d["kind"] }.uniq}" unless docs.all? { |d| d["kind"] == "ConfigMap" }
expected_names = DASHBOARDS.keys.map { |n| "persona-dashboard-#{n}" }.sort
raise "[안전] ConfigMap 이름이 #{expected_names}가 아니다(실제 #{docs.map { |d| d.dig("metadata", "name") }.sort})" unless docs.map { |d| d.dig("metadata", "name") }.sort == expected_names

manifest = File.readlines(File.join(base, "SOURCE.sha256"), chomp: true).to_h { |line| line.split("  ", 2).reverse }
raise "[안전] SOURCE.sha256에 대시보드 4개가 있어야 한다" unless manifest.keys.sort == DASHBOARDS.keys.map { |n| "#{n}.json" }.sort

uids = []
docs.each do |doc|
  name = doc.dig("metadata", "name")
  key = name.delete_prefix("persona-dashboard-")
  file = "#{key}.json"
  raise "[안전] #{name}: namespace는 monitoring이다" unless doc.dig("metadata", "namespace") == "monitoring"
  raise "[안전] #{name}: sidecar 라벨 grafana_dashboard=\"1\"이 없다(자동 로딩 불가)" unless doc.dig("metadata", "labels", "grafana_dashboard") == "1"
  raise "[안전] #{name}: data 키는 #{file} 하나여야 한다" unless doc["data"].keys == [file]
  content = doc["data"][file]
  raise "[안전] #{name}: ConfigMap 크기가 한도를 넘는다(#{content.bytesize}B)" if content.bytesize > CONFIGMAP_LIMIT

  copy = File.binread(File.join(base, file))
  digest = Digest::SHA256.hexdigest(copy)
  raise "[안전] #{file}: 배포 사본이 SOURCE.sha256(정본 해시)과 다르다 — 정본에서 다시 생성한다" unless manifest[file] == digest
  raise "[안전] #{name}: 렌더한 내용이 배포 사본과 다르다" unless content.b == copy

  dash = JSON.parse(content)
  raise "[안전] #{file}: uid는 #{DASHBOARDS[key]}이다(기본 Kubernetes 대시보드와 겹치지 않는 persona- 접두사)" unless dash["uid"] == DASHBOARDS[key]
  uids << dash["uid"]
  raise "[안전] #{file}: __inputs가 남아 있으면 자동 로딩이 깨진다" if dash.key?("__inputs")
  raise "[안전] #{file}: ${DS_*} 참조가 남아 있다" if content.include?("${DS_")
  each_datasource(dash) do |ds|
    next if ds.nil? || ALLOWED_DATASOURCES.include?(ds)
    raise "[안전] #{file}: datasource 참조가 prometheus(uid)가 아니다: #{ds.inspect}"
  end
  ids = []
  each_panel(dash["panels"] || []) { |panel| ids << panel["id"] }
  dup = ids.select { |id| ids.count(id) > 1 }.uniq
  raise "[안전] #{file}: 패널 ID 충돌 #{dup}" unless dup.empty?
  raise "[기준선] #{file}: 기본 시간 30분·새로고침 30초가 아니다" unless dash.dig("time", "from") == "now-30m" && dash["refresh"] == "30s"
end
raise "[안전] 대시보드 UID가 서로 겹친다" unless uids.uniq.length == uids.length

# --- monitoring-stack Application 보존 -----------------------------------------
app = YAML.load_file(File.join(repo, "argocd/monitoring-stack.yaml"))
sources = app.dig("spec", "sources") || []
raise "[안전] monitoring-stack source는 차트와 values ref 두 개여야 한다(새 source를 늘리지 않는다)" unless sources.length == 2
chart, values = sources
raise "[안전] 차트 source가 바뀌었다(repoURL·chart·89.2.0·releaseName·valueFiles 보존)" unless chart["repoURL"] == "https://prometheus-community.github.io/helm-charts" && chart["chart"] == "kube-prometheus-stack" && chart["targetRevision"] == "89.2.0" && chart.dig("helm", "releaseName") == "monitoring-stack" && chart.dig("helm", "valueFiles") == ["$values/helm/values/monitoring-stack.yaml"]
raise "[안전] values ref source가 바뀌었다(repoURL·develop·ref: values)" unless values["repoURL"] == "https://github.com/MAfest-Runtime/mafest-platform.git" && values["targetRevision"] == "develop" && values["ref"] == "values"
raise "[안전] values source의 path는 kustomize/overlays/prod/grafana-dashboards여야 대시보드가 렌더된다" unless values["path"] == "kustomize/overlays/prod/grafana-dashboards"
sync = app.dig("spec", "syncPolicy") || {}
raise "[안전] monitoring-stack에 자동 Sync를 켜지 않는다(수동 Sync 원칙)" if sync.key?("automated")
raise "[안전] ServerSideApply=true를 유지한다(큰 CRD·큰 ConfigMap)" unless (sync["syncOptions"] || []).include?("ServerSideApply=true")
raise "[안전] monitoring-stack에 finalizer를 두지 않는다" if app.dig("metadata", "finalizers")
raise "[안전] 대상 namespace는 monitoring이다" unless app.dig("spec", "destination", "namespace") == "monitoring"

puts "Grafana 대시보드 ConfigMap 4개(렌더·크기·정본 해시·UID·패널 ID·datasource)와 monitoring-stack 연결 검사 통과"
RUBY
