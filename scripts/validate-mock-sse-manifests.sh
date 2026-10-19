#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
rendered_file=$(mktemp "${TMPDIR:-/tmp}/persona-mock-sse.XXXXXX.yaml")
trap 'rm -f "$rendered_file"' EXIT HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/overlays/prod/mock-sse" > "$rendered_file"

# Argo Application 선언은 2026-09-16 등록 해제로 저장소에서 빠졌다. 검사 대상이 없으므로
# 인자에서도 뺀다. 다시 등록할 때는 선언 파일과 함께 아래 Application 검사도 되살린다.
# 선언 원문과 재등록 순서는 runbooks/test-resource-cleanup.md에 있다.
ruby -ryaml - "$rendered_file" "$repo_dir/bootstrap/namespaces/persona-mock-sse.yaml" <<'RUBY'
rendered_path, namespace_path = ARGV
resources = YAML.load_stream(File.read(rendered_path)).compact

def resource(resources, kind, name)
  resources.find { |item| item["kind"] == kind && item.dig("metadata", "name") == name } ||
    raise("missing #{kind}/#{name}")
end

deployment = resource(resources, "Deployment", "persona-mock-sse")
raise "Argo overlay must not manage the bootstrap Namespace" if resources.any? { |item| item["kind"] == "Namespace" }
spec = deployment.fetch("spec")
raise "mock SSE must have one replica" unless spec["replicas"] == 1
raise "mock SSE must use a zero-surge rollout" unless spec.dig("strategy", "rollingUpdate", "maxSurge") == 0

pod_spec = spec.dig("template", "spec")
raise "service account token mount must be disabled" unless pod_spec["automountServiceAccountToken"] == false
raise "termination grace period must be 15 seconds" unless pod_spec["terminationGracePeriodSeconds"] == 15
raise "GHCR pull Secret is missing" unless pod_spec["imagePullSecrets"] == [{"name" => "persona-mock-sse-ghcr"}]
raise "RuntimeDefault seccomp is required" unless pod_spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"

nodes = pod_spec.dig("affinity", "nodeAffinity", "requiredDuringSchedulingIgnoredDuringExecution", "nodeSelectorTerms", 0, "matchExpressions", 0, "values")
raise "mock SSE must target only home workers" unless nodes == ["k8s-worker1", "k8s-worker2"]

container = pod_spec.fetch("containers").find { |item| item["name"] == "mock-sse" } || raise("mock-sse container missing")
image = container.fetch("image")
expected_image = "ghcr.io/mafest-runtime/persona-mock-sse@sha256:c467296f090f3868d32d82dda92ab2aaf75b096bae1ae0a0c1e1fde4bf58666d"
raise "image must use the verified linux/amd64 child manifest digest" unless image == expected_image
raise "container port must be 8080" unless container.dig("ports", 0, "containerPort") == 8080
raise "grace period must be passed to the server" unless container.dig("env", 0, "name") == "MOCK_SSE_GRACE_PERIOD_SECONDS" && container.dig("env", 0, "value") == "5"
security = container.fetch("securityContext")
raise "container must run non-root" unless security["runAsNonRoot"] == true && security["runAsUser"] == 10_001
raise "privilege escalation must be disabled" unless security["allowPrivilegeEscalation"] == false
raise "all Linux capabilities must be dropped" unless security.dig("capabilities", "drop") == ["ALL"]
raise "root filesystem must be read-only" unless security["readOnlyRootFilesystem"] == true
raise "health startup probe missing" unless container.dig("startupProbe", "httpGet", "path") == "/healthz"
raise "health liveness probe missing" unless container.dig("livenessProbe", "httpGet", "path") == "/healthz"
raise "readiness probe missing" unless container.dig("readinessProbe", "httpGet", "path") == "/readyz"

service = resource(resources, "Service", "persona-mock-sse")
raise "Service must be ClusterIP" unless service.dig("spec", "type") == "ClusterIP"
raise "Service must expose port 8080" unless service.dig("spec", "ports", 0, "port") == 8080

gateway = resource(resources, "Gateway", "persona-mock-sse")
raise "Gateway must use Traefik" unless gateway.dig("spec", "gatewayClassName") == "traefik"
listener = gateway.dig("spec", "listeners", 0)
raise "Gateway must use Traefik's HTTP entryPoint port 8000" unless listener["name"] == "http" && listener["protocol"] == "HTTP" && listener["port"] == 8000

route = resource(resources, "HTTPRoute", "persona-mock-sse")
match = route.dig("spec", "rules", 0, "matches", 0)
raise "Route must expose POST only" unless match["method"] == "POST"
raise "Route must preserve the exact mock chat path" unless match.dig("path", "type") == "Exact" && match.dig("path", "value") == "/mock/chat"
raise "Route must target the mock Service" unless route.dig("spec", "rules", 0, "backendRefs", 0, "name") == "persona-mock-sse" && route.dig("spec", "rules", 0, "backendRefs", 0, "port") == 8080

namespace = YAML.load_file(namespace_path)
raise "bootstrap Namespace kind is invalid" unless namespace["kind"] == "Namespace"
raise "bootstrap Namespace name is invalid" unless namespace.dig("metadata", "name") == "persona-mock-sse"

puts "mock SSE Kustomize render and manifest policy checks passed (Argo Application is de-registered)"
RUBY
