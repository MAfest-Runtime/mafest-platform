#!/bin/sh

set -eu

# bootstrap/cilium/values.yaml로 렌더한 Cilium이 지표 수집 선언(ServiceMonitor 2개, 라벨,
# hubble metrics 옵션)을 실제로 내는지 로컬에서만 검사한다. 클러스터를 호출하지 않는다.
#
# 왜 렌더 결과를 보는가: helm은 모르는 values 키를 오류 없이 무시한다. 키 이름이 틀리면
# values.yaml에는 선언이 있어도 ServiceMonitor가 만들어지지 않아, 지표가 비어 있는 것을
# 장애가 난 뒤에야 알게 된다. chart 버전은 bootstrap/cilium/README.md의 설치 명령과 같아야 한다.
# chart는 네트워크로 받는다. 오프라인에서는 실행되지 않는다.

for tool in helm ruby mktemp grep; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
chart_version=1.20.1
rendered_file=$(mktemp "${TMPDIR:-/tmp}/cilium-metrics.XXXXXX.yaml")
trap 'rm -f "$rendered_file"' EXIT
trap 'exit 1' HUP INT TERM

helm template cilium cilium --repo https://helm.cilium.io --version "$chart_version" \
  -n kube-system -f "$repo_dir/bootstrap/cilium/values.yaml" > "$rendered_file"

ruby -ryaml - "$rendered_file" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8

resources = YAML.load_stream(File.read(ARGV.fetch(0))).compact

# 1. kube-prometheus-stack은 release 라벨이 있는 ServiceMonitor만 고른다.
%w[cilium-agent hubble].each do |name|
  monitor = resources.find { |r| r["kind"] == "ServiceMonitor" && r.dig("metadata", "name") == name } ||
    raise("[안전] ServiceMonitor/#{name}이 렌더에 없다 — values 키 이름을 확인한다")
  unless monitor.dig("metadata", "labels", "release") == "monitoring-stack"
    raise "[안전] ServiceMonitor/#{name}에 release: monitoring-stack 라벨이 없어 수집되지 않는다"
  end
end

# 2. hubble metrics는 dns와 drop을 켜고, 라벨을 namespace로 제한한 옵션을 유지한다.
config = resources.find { |r| r["kind"] == "ConfigMap" && r.dig("metadata", "name") == "cilium-config" } ||
  raise("[안전] cilium-config ConfigMap이 렌더에 없다")
metrics = config.dig("data", "hubble-metrics").to_s.split
%w[dns drop].each do |kind|
  entry = metrics.find { |m| m == kind || m.start_with?("#{kind}:") } ||
    raise("[안전] hubble metrics에 #{kind}가 없다")
  unless entry.include?("labelsContext=source_namespace,destination_namespace")
    raise "[기준선] hubble #{kind}가 namespace 수준 라벨로 제한되지 않았다: #{entry}"
  end
end

puts "Cilium 지표 수집 선언 검사 통과"
RUBY
