#!/bin/sh

set -eu

# GPU-00 관측 경로를 로컬 렌더 결과만으로 검사한다. 이 스크립트는 클러스터를 읽거나
# Argo Sync하지 않는다. Target이 실제로 UP인지와 exporter가 GPU를 읽는지는 Sync 뒤
# 운영 확인 단계에서만 판정한다.

for tool in helm kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
dcgm_app="$repo_dir/argocd/dcgm-exporter.yaml"
runtime_app="$repo_dir/argocd/gpu-runtime.yaml"
device_plugin_app="$repo_dir/argocd/nvidia-device-plugin.yaml"
values_file="$repo_dir/helm/values/dcgm-exporter.yaml"
runtime_dir="$repo_dir/kustomize/overlays/prod/gpu-runtime"
device_plugin_dir="$repo_dir/kustomize/overlays/prod/nvidia-device-plugin"
rendered_file=$(mktemp "${TMPDIR:-/tmp}/dcgm-exporter.XXXXXX.yaml")
runtime_file=$(mktemp "${TMPDIR:-/tmp}/gpu-runtime.XXXXXX.yaml")
device_plugin_file=$(mktemp "${TMPDIR:-/tmp}/nvidia-device-plugin.XXXXXX.yaml")
trap 'rm -f "$rendered_file" "$runtime_file" "$device_plugin_file"' EXIT HUP INT TERM

read_dcgm_field() {
  ruby -ryaml -e '# encoding: utf-8
    app = YAML.load_file(ARGV[0])
    source = app.fetch("spec").fetch("sources").find { |item| item.key?("chart") } ||
      abort("[안전] dcgm-exporter에 Helm chart source가 없다")
    key = ARGV[1]
    value = case key
            when "repoURL", "chart", "targetRevision" then source[key]
            when "releaseName" then source.dig("helm", key)
            else abort("[안전] 알 수 없는 chart 필드: #{key}")
            end
    abort "[안전] dcgm-exporter chart #{key}가 없다" if value.nil?
    puts value
  ' "$dcgm_app" "$1"
}

chart_repo=$(read_dcgm_field repoURL)
chart_name=$(read_dcgm_field chart)
chart_version=$(read_dcgm_field targetRevision)
release_name=$(read_dcgm_field releaseName)

kubectl kustomize "$runtime_dir" > "$runtime_file"
kubectl kustomize "$device_plugin_dir" > "$device_plugin_file"
helm template "$release_name" "$chart_name" --repo "$chart_repo" --version "$chart_version" \
  -n monitoring -f "$values_file" > "$rendered_file"

ruby -ryaml - "$runtime_app" "$dcgm_app" "$device_plugin_app" \
  "$runtime_file" "$device_plugin_file" "$rendered_file" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8

runtime_app_path, dcgm_app_path, device_plugin_app_path,
  runtime_path, device_plugin_path, rendered_path = ARGV
runtime_app = YAML.load_file(runtime_app_path)
dcgm_app = YAML.load_file(dcgm_app_path)
device_plugin_app = YAML.load_file(device_plugin_app_path)
runtime = YAML.load_stream(File.read(runtime_path)).compact
device_plugin = YAML.load_stream(File.read(device_plugin_path)).compact
resources = YAML.load_stream(File.read(rendered_path)).compact

def resource(all, kind, name)
  all.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } ||
    raise("[안전] #{kind}/#{name}이 렌더 결과에 없다")
end

# RuntimeClass는 containerd handler 이름과 같은 `nvidia`여야 한다. handler가 어긋나면
# Pod가 GPU 없이 실행되거나 아예 생성되지 않을 수 있으므로 chart보다 먼저 고정한다.
raise "[안전] gpu-runtime: Application kind가 아니다" unless runtime_app["kind"] == "Application"
raise "[안전] gpu-runtime: 이름이 다르다" unless runtime_app.dig("metadata", "name") == "gpu-runtime"
runtime_source = runtime_app.fetch("spec").fetch("source")
raise "[안전] gpu-runtime: develop 브랜치를 봐야 한다" unless runtime_source["targetRevision"] == "develop"
raise "[안전] gpu-runtime: source path가 다르다" unless runtime_source["path"] == "kustomize/overlays/prod/gpu-runtime"
raise "[안전] gpu-runtime: 자동 Sync를 켜면 안 된다" if runtime_app.dig("spec", "syncPolicy", "automated")

runtime_class = resource(runtime, "RuntimeClass", "nvidia")
raise "[안전] RuntimeClass/nvidia handler가 nvidia가 아니다" unless runtime_class["handler"] == "nvidia"
raise "[안전] RuntimeClass/nvidia GPU 노드 선택자가 다르다" unless
  runtime_class.dig("scheduling", "nodeSelector") == { "personaruntime.xyz/node-pool" => "gpu" }
expected_toleration = [{ "key" => "personaruntime.xyz/dedicated", "operator" => "Equal",
                         "value" => "gpu-serving", "effect" => "NoSchedule" }]
raise "[안전] RuntimeClass/nvidia taint 허용 범위가 다르다" unless
  runtime_class.dig("scheduling", "tolerations") == expected_toleration

# Device plugin은 host driver를 직접 검사해 kubelet에 nvidia.com/gpu capacity를 등록한다.
# GPU Operator·time-slicing·자동 Feature Discovery를 섞지 않고, 한 GPU 노드에 하나만
# 배치되는 DaemonSet과 hostPath socket mount만 허용한다.
raise "[안전] nvidia-device-plugin: Application kind가 아니다" unless device_plugin_app["kind"] == "Application"
raise "[안전] nvidia-device-plugin: 이름이 다르다" unless
  device_plugin_app.dig("metadata", "name") == "nvidia-device-plugin"
plugin_source = device_plugin_app.fetch("spec").fetch("source")
raise "[안전] nvidia-device-plugin: develop 브랜치를 봐야 한다" unless plugin_source["targetRevision"] == "develop"
raise "[안전] nvidia-device-plugin: source path가 다르다" unless
  plugin_source["path"] == "kustomize/overlays/prod/nvidia-device-plugin"
raise "[안전] nvidia-device-plugin: 자동 Sync를 켜면 안 된다" if
  device_plugin_app.dig("spec", "syncPolicy", "automated")

plugin_daemon_set = resource(device_plugin, "DaemonSet", "nvidia-device-plugin-daemonset")
plugin_pod = plugin_daemon_set.dig("spec", "template", "spec") ||
  raise("[안전] nvidia-device-plugin DaemonSet Pod spec이 없다")
raise "[안전] nvidia-device-plugin은 RuntimeClass/nvidia를 써야 한다" unless plugin_pod["runtimeClassName"] == "nvidia"
raise "[안전] nvidia-device-plugin GPU nodeSelector가 다르다" unless
  plugin_pod["nodeSelector"] == { "personaruntime.xyz/node-pool" => "gpu" }
raise "[안전] nvidia-device-plugin 우선순위가 system-node-critical이 아니다" unless
  plugin_pod["priorityClassName"] == "system-node-critical"
expected_plugin_tolerations = expected_toleration + [{ "key" => "nvidia.com/gpu", "operator" => "Exists", "effect" => "NoSchedule" }]
raise "[안전] nvidia-device-plugin taint 허용 범위가 다르다" unless
  plugin_pod["tolerations"] == expected_plugin_tolerations
plugin = (plugin_pod["containers"] || []).find { |item| item["name"] == "nvidia-device-plugin-ctr" } ||
  raise("[안전] nvidia-device-plugin 컨테이너가 없다")
raise "[기준선] nvidia-device-plugin image가 v0.20.1이 아니다" unless
  plugin["image"] == "nvcr.io/nvidia/k8s-device-plugin:v0.20.1"
raise "[안전] nvidia-device-plugin 권한이 NVIDIA static 기준선보다 넓다" unless
  plugin["securityContext"] == { "allowPrivilegeEscalation" => false, "capabilities" => { "drop" => ["ALL"] } }
mounts = plugin["volumeMounts"] || []
raise "[안전] nvidia-device-plugin kubelet socket mount가 없다" unless mounts == [{
  "name" => "kubelet-device-plugins-dir", "mountPath" => "/var/lib/kubelet/device-plugins"
}]
raise "[안전] nvidia-device-plugin hostPath가 다르다" unless plugin_pod["volumes"] == [{
  "name" => "kubelet-device-plugins-dir",
  "hostPath" => { "path" => "/var/lib/kubelet/device-plugins", "type" => "Directory" }
}]

# 두 source의 역할을 고정한다. 차트 source만 바뀌거나 values Git source가 develop이 아닌
# revision을 보면, 사람이 검토한 values와 Argo가 실제 읽는 values가 갈라질 수 있다.
raise "[안전] dcgm-exporter: Application kind가 아니다" unless dcgm_app["kind"] == "Application"
raise "[안전] dcgm-exporter: 이름이 다르다" unless dcgm_app.dig("metadata", "name") == "dcgm-exporter"
raise "[안전] dcgm-exporter: 자동 Sync를 켜면 안 된다" if dcgm_app.dig("spec", "syncPolicy", "automated")
sources = dcgm_app.dig("spec", "sources") || raise("[안전] dcgm-exporter: multi-source가 없다")
chart_source = sources.find { |item| item.key?("chart") } || raise("[안전] dcgm-exporter: Helm chart source가 없다")
values_source = sources.find { |item| item["ref"] == "values" } || raise("[안전] dcgm-exporter: values source가 없다")
raise "[안전] dcgm-exporter chart 좌표가 다르다" unless
  [chart_source["repoURL"], chart_source["chart"], chart_source["targetRevision"]] ==
  ["https://nvidia.github.io/dcgm-exporter/helm-charts", "dcgm-exporter", "4.8.4"]
raise "[안전] dcgm-exporter releaseName이 다르다" unless chart_source.dig("helm", "releaseName") == "dcgm-exporter"
raise "[안전] dcgm-exporter values 파일이 다르다" unless
  chart_source.dig("helm", "valueFiles") == ["$values/helm/values/dcgm-exporter.yaml"]
raise "[안전] dcgm-exporter values source가 develop을 보지 않는다" unless
  values_source["repoURL"] == "https://github.com/MAfest-Runtime/mafest-platform.git" &&
  values_source["targetRevision"] == "develop"

daemon_set = resource(resources, "DaemonSet", "dcgm-exporter")
pod_spec = daemon_set.dig("spec", "template", "spec") || raise("[안전] DCGM DaemonSet Pod spec이 없다")
raise "[안전] DCGM은 RuntimeClass/nvidia를 써야 한다" unless pod_spec["runtimeClassName"] == "nvidia"
# chart는 false를 명시하지 않고 필드를 생략한다. 따라서 false 또는 생략은 허용하고,
# 실제로 hostNetwork=true가 된 경우만 막는다.
raise "[안전] DCGM hostNetwork를 켜면 안 된다" if pod_spec["hostNetwork"] == true
raise "[안전] DCGM hostPID를 켜면 안 된다" unless pod_spec["hostPID"] == false
raise "[기준선] DCGM priorityClassName을 설정하면 안 된다" unless pod_spec["priorityClassName"].to_s.empty?
raise "[안전] DCGM nodeSelector가 GPU 전용이 아니다" unless
  pod_spec["nodeSelector"] == { "personaruntime.xyz/node-pool" => "gpu" }
raise "[안전] DCGM taint 허용 범위가 다르다" unless pod_spec["tolerations"] == expected_toleration
raise "[안전] DCGM ServiceAccount token mount를 켜면 안 된다" unless pod_spec["automountServiceAccountToken"] == false

exporter = (pod_spec["containers"] || []).find { |item| item["name"] == "exporter" } ||
  raise("[안전] DCGM exporter 컨테이너가 없다")
raise "[기준선] DCGM image가 검토한 tag가 아니다" unless
  exporter["image"] == "nvcr.io/nvidia/k8s/dcgm-exporter:4.6.1-4.8.4-distroless"
raise "[안전] DCGM resources가 기준선과 다르다" unless exporter["resources"] == {
  "requests" => { "cpu" => "100m", "memory" => "128Mi" },
  "limits" => { "cpu" => "200m", "memory" => "512Mi" },
}
expected_security = {
  "runAsNonRoot" => false, "runAsUser" => 0,
  "capabilities" => { "add" => ["SYS_ADMIN"], "drop" => ["ALL"] },
  "allowPrivilegeEscalation" => false,
}
raise "[안전] DCGM securityContext가 검토한 최소 범위와 다르다" unless exporter["securityContext"] == expected_security

service = resource(resources, "Service", "dcgm-exporter")
raise "[안전] DCGM Service가 ClusterIP가 아니다" unless service.dig("spec", "type") == "ClusterIP"
raise "[안전] DCGM Service metrics port가 9400이 아니다" unless service.dig("spec", "ports") ==
  [{ "name" => "metrics", "port" => 9400, "targetPort" => 9400, "protocol" => "TCP" }]

monitor = resource(resources, "ServiceMonitor", "dcgm-exporter")
raise "[안전] DCGM ServiceMonitor에 release=monitoring-stack 라벨이 없다" unless
  monitor.dig("metadata", "labels", "release") == "monitoring-stack"
raise "[안전] DCGM ServiceMonitor endpoint가 다르다" unless monitor.dig("spec", "endpoints") == [{
  "port" => "metrics", "path" => "/metrics", "interval" => "30s",
  "scrapeTimeout" => "10s", "honorLabels" => false,
  # chart는 비어 있는 relabeling 목록도 명시한다. 이 목록을 허용하지 않으면 전체
  # endpoint를 바꾼 경우와 단순 기본값 표현을 구분할 수 없다.
  "relabelings" => [], "metricRelabelings" => [],
}]

puts "GPU RuntimeClass·DCGM exporter·NVIDIA device plugin 렌더 계약 검사 통과"
RUBY
