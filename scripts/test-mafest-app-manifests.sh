#!/bin/sh
# 원본 선언을 바꾸지 않고 복사본에 결함을 하나씩 넣어 validate-mafest-app-manifests.sh가 실패하는지 확인한다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/mafest-app-test.XXXXXX")
# 이 실행이 만든 복사본만 제거하며 원본·클러스터는 변경하지 않는다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-mafest-app-manifests.sh" "$test_dir/scripts/"
# 깨끗한 복사본은 먼저 통과해야 한다. 아니면 아래 실패가 결함 때문인지 알 수 없다.
sh "$test_dir/scripts/validate-mafest-app-manifests.sh" > /dev/null

ruby -ryaml -rfileutils - "$test_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8

root = ARGV.fetch(0)
API = "kustomize/base/mafest-app/api-deployment.yaml"
WEB = "kustomize/base/mafest-app/web-deployment.yaml"
PDB = "kustomize/base/mafest-app/api-pdb.yaml"
OVERLAY = "kustomize/overlays/prod/mafest-app/kustomization.yaml"
GRANT = "kustomize/base/mafest-app/referencegrant-public.yaml"
POD = ["spec", "template", "spec"]
C0 = POD + ["containers", 0]

def mutate_yaml(path, keys, value)
  document = YAML.load_file(path)
  parent = keys[0...-1].reduce(document) { |node, key| node.fetch(key) }
  value == :delete ? parent.delete(keys.last) : parent[keys.last] = value
  File.write(path, YAML.dump(document))
end

def env_list(path)
  YAML.load_file(path).dig(*C0, "env")
end

# [설명, 복사본을 바꾸는 함수, 기대 오류 문구]
cases = [
  ["API replica 3", ->(r) { mutate_yaml(File.join(r, API), ["spec", "replicas"], 3) }, "API는 replicas 2다"],
  ["Uvicorn worker를 args로 늘림", ->(r) { mutate_yaml(File.join(r, API), C0 + ["args"], ["--workers", "2"]) }, "승인 실행 형태"],
  ["graceful 종료 시간 변경", ->(r) {
     args = YAML.load_file(File.join(r, API)).dig(*C0, "args").map { |a| a == "100" ? "30" : a }
     mutate_yaml(File.join(r, API), C0 + ["args"], args)
   }, "승인 실행 형태"],
  ["command 덮어씀", ->(r) { mutate_yaml(File.join(r, API), C0 + ["command"], ["python"]) }, "command를 덮어쓰지 않는다"],
  ["preStop 제거", ->(r) { mutate_yaml(File.join(r, API), C0 + ["lifecycle"], :delete) }, "preStop은 exec sleep 10"],
  ["DB의 required anti-affinity 복사", ->(r) {
     term = { "topologyKey" => "kubernetes.io/hostname", "labelSelector" => { "matchLabels" => { "app.kubernetes.io/name" => "mafest-api" } } }
     mutate_yaml(File.join(r, API), POD + ["affinity", "podAntiAffinity"], { "requiredDuringSchedulingIgnoredDuringExecution" => [term] })
   }, "required podAntiAffinity를 두지 않는다"],
  ["readiness에 deep 경로", ->(r) { mutate_yaml(File.join(r, API), C0 + ["readinessProbe", "httpGet", "path"], "/readyz?deep=1") }, "readiness는 기본 /readyz"],
  ["owner Secret 연결", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "PGURL" ? { "name" => "PGURL", "valueFrom" => { "secretKeyRef" => { "name" => "mafest-migrator", "key" => "PGURL" } } } : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "mafest-api-db의 PGURL"],
  ["세션 DSN 누락", ->(r) {
     env = env_list(File.join(r, API)).reject { |e| e["name"] == "PGURL_SESSION" }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "PGURL_SESSION이 없다"],
  ["세션 서버 키를 다른 Secret으로 분리", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "MAFEST_SESSION_KEY" ? { "name" => "MAFEST_SESSION_KEY", "valueFrom" => { "secretKeyRef" => { "name" => "mafest-api-key-other", "key" => "MAFEST_SESSION_KEY" } } } : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "mafest-api-session의 MAFEST_SESSION_KEY"],
  ["세션 DSN에 DDL Secret 연결", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "PGURL_SESSION" ? { "name" => "PGURL_SESSION", "valueFrom" => { "secretKeyRef" => { "name" => "mafest-db-owner", "key" => "PGURL_SESSION" } } } : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "mafest-api-session의 PGURL_SESSION"],
  ["세션 DSN에 마이그레이션 전용 Secret 연결", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "PGURL_SESSION" ? { "name" => "PGURL_SESSION", "valueFrom" => { "secretKeyRef" => { "name" => "mafest-session-migrate-db", "key" => "PGURL" } } } : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "mafest-api-session의 PGURL_SESSION"],
  ["마이그레이션 DSN 이름을 API에 추가", ->(r) {
     mutate_yaml(File.join(r, API), C0 + ["env"], env_list(File.join(r, API)) + [{ "name" => "PGURL_SESSION_MIGRATE", "value" => "x" }])
   }, "Settings가 읽지 않는 환경변수"],
  ["확인 질문 기능 끔", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "MAFEST_LLM_INTENT" ? e.merge("value" => "0") : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "MAFEST_LLM_INTENT는"],
  ["요약 켜짐으로 회귀", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "MAFEST_LLM_SUMMARY" ? e.merge("value" => "1") : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "MAFEST_LLM_SUMMARY는"],
  ["자동 재시도 켜짐으로 회귀", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "MAFEST_LLM_RETRIES" ? e.merge("value" => "1") : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "MAFEST_LLM_RETRIES는"],
  ["세션 풀이 연결 예산을 넘김", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "MAFEST_SESSION_POOL_MAX" ? e.merge("value" => "2") : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
     # 승인값은 2다. 예산 검사는 max_connections 를 낮춰 넘기는 방식으로 확인한다.
     mutate_yaml(File.join(r, "kustomize/base/mafest-db/cluster.yaml"), ["spec", "postgresql", "parameters", "max_connections"], "40")
   }, "max_connections"],
  ["지어낸 환경변수 이름", ->(r) {
     mutate_yaml(File.join(r, API), C0 + ["env"], env_list(File.join(r, API)) + [{ "name" => "VLLM_URL", "value" => "http://x" }])
   }, "Settings가 읽지 않는 환경변수"],
  ["종료 유예 45초", ->(r) { mutate_yaml(File.join(r, API), POD + ["terminationGracePeriodSeconds"], 45) }, "API 종료 유예는"],
  ["승인 외 기준일", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "MAFEST_DATA_BASE_DATE" ? e.merge("value" => "2026-09-01") : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "MAFEST_DATA_BASE_DATE는"],
  ["생성 시한 20초로 회귀", ->(r) {
     env = env_list(File.join(r, API)).map { |e| e["name"] == "MAFEST_LLM_TIMEOUT_S" ? e.merge("value" => "20") : e }
     mutate_yaml(File.join(r, API), C0 + ["env"], env)
   }, "MAFEST_LLM_TIMEOUT_S는"],
  ["API 승인 외 digest", ->(r) { mutate_yaml(File.join(r, API), C0 + ["image"], "ghcr.io/persona-runtime/mafest-app@sha256:" + "a" * 64) }, "승인 digest가 아니다"],
  ["웹 자리표시 digest", ->(r) { mutate_yaml(File.join(r, WEB), C0 + ["image"], "ghcr.io/persona-runtime/mafest-web@sha256:" + "0" * 64) }, "승인 digest가 아니다"],
  ["Application에 자동 Sync", ->(r) { mutate_yaml(File.join(r, "argocd/mafest-app.yaml"), ["spec", "syncPolicy"], { "automated" => {} }) }, "자동 Sync를 두지 않는다"],
  ["overlay가 API 이미지 digest를 바꿈", ->(r) {
     path = File.join(r, OVERLAY)
     File.write(path, File.read(path) + "images:\n  - name: ghcr.io/persona-runtime/mafest-app\n    digest: sha256:" + "b" * 64 + "\n")
   }, "(prod) API 이미지가 승인 digest가 아니다"],
  ["overlay가 생성 시한을 바꿈", ->(r) {
     path = File.join(r, OVERLAY)
     patch = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: mafest-api\nspec:\n  template:\n    spec:\n      containers:\n        - name: api\n          env:\n            - name: MAFEST_LLM_TIMEOUT_S\n              value: \"20\"\n"
     File.write(path, File.read(path) + "patches:\n  - patch: |-\n" + patch.lines.map { |l| "      " + l }.join)
   }, "(prod) API 환경변수 MAFEST_LLM_TIMEOUT_S는"],
  ["옛 공개 초안 경로 연결", ->(r) {
     FileUtils.mkdir_p(File.join(r, "kustomize/base/mafest-public"))
     File.write(File.join(r, "kustomize/base/mafest-public/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n")
   }, "옛 공개 라우트 초안"],
]

cases.each do |label, mutate, message|
  case_dir = File.join(root, "case")
  FileUtils.rm_rf(case_dir)
  FileUtils.mkdir_p(case_dir)
  %w[kustomize argocd scripts].each { |dir| FileUtils.cp_r(File.join(root, dir), case_dir) }
  mutate.call(case_dir)
  output_path = File.join(case_dir, "result.log")
  success = system("sh", File.join(case_dir, "scripts/validate-mafest-app-manifests.sh"), out: output_path, err: [:child, :out])
  raise "회귀 검사가 결함을 놓쳤다: #{label}" if success
  raise "예상과 다른 검사 오류다(#{label}): #{message}\n#{File.read(output_path)}" unless File.read(output_path).include?(message)
  puts "검출: #{label}"
end
puts "mafest-app 음성 테스트 #{cases.length}건 통과"
RUBY
