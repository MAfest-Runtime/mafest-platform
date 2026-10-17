#!/bin/sh
# 원본 선언을 바꾸지 않고 복사본에 결함을 하나씩 넣어 validate-mafest-data-manifests.sh가 실패하는지 확인한다.
set -eu
for tool in kubectl ruby mktemp cp mkdir rm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "필요한 도구가 없습니다: $tool" >&2; exit 1; }
done
repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/mafest-data-test.XXXXXX")
# 이 실행이 만든 복사본만 제거하며 원본·클러스터는 변경하지 않는다.
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cp -R "$repo_dir/kustomize" "$repo_dir/argocd" "$repo_dir/bootstrap" "$repo_dir/db" "$test_dir/"
mkdir "$test_dir/scripts"
cp "$repo_dir/scripts/validate-mafest-data-manifests.sh" "$test_dir/scripts/"
# 깨끗한 복사본은 먼저 통과해야 한다. 아니면 아래 실패가 결함 때문인지 알 수 없다.
sh "$test_dir/scripts/validate-mafest-data-manifests.sh" > /dev/null

ruby -ryaml - "$test_dir" <<'RUBY'
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8

root = ARGV.fetch(0)
CLUSTER = "kustomize/base/mafest-db/cluster.yaml"
STAGE = "kustomize/base/mafest-load/job-stage.yaml"
GRAPH = "kustomize/base/mafest-load/job-graph.yaml"
LOAD_K = "kustomize/base/mafest-load/kustomization.yaml"
DB_K = "kustomize/base/mafest-db/kustomization.yaml"
NETPOL = "kustomize/base/networkpolicy/mafest-data/network-policy.yaml"
ROLES = "db/grants/mafest_roles.sql"
SESSION_CHECK = "db/grants/mafest_session_check.sql"
SESSION_PRECHECK = "db/grants/mafest_session_precheck.sql"
POD = ["spec", "template", "spec"]
C0 = POD + ["containers", 0]

# YAML 한 문서(또는 여러 문서 중 이름이 맞는 것)의 키 경로를 바꾼다. value가 :delete면 키를 지운다.
def mutate_yaml(path, keys, value, name: nil)
  documents = YAML.load_stream(File.read(path)).compact
  document = name ? documents.find { |d| d.dig("metadata", "name") == name } : documents.first
  raise "사례 문서를 찾지 못했다: #{name}" unless document
  parent = keys[0...-1].reduce(document) { |node, key| node.fetch(key) }
  value == :delete ? parent.delete(keys.last) : parent[keys.last] = value
  File.write(path, documents.map { |d| YAML.dump(d) }.join)
end


# [사례 설명, 복사본을 바꾸는 함수, 기대 오류 문구 일부]
cases = [
  # Cluster
  ["instances 1", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "instances"], 1) }, "instances는 2다"],
  ["anti-affinity preferred", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "affinity", "podAntiAffinityType"], "preferred") }, "anti-affinity는 required다"],
  ["anti-affinity off", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "affinity", "enablePodAntiAffinity"], false) }, "enablePodAntiAffinity가 켜져"],
  ["GPU 노드 후보 추가", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "affinity", "nodeAffinity", "requiredDuringSchedulingIgnoredDuringExecution", "nodeSelectorTerms", 0, "matchExpressions", 0, "values"], %w[k8s-worker1 k8s-worker2 persona-gpu-01]) }, "두 홈 워커"],
  ["AGE preload 누락", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "postgresql", "shared_preload_libraries"], []) }, "shared_preload_libraries에 age"],
  ["jit on", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "postgresql", "parameters", "jit"], "on") }, "jit은 off"],
  ["Delete=false 누락", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["metadata", "annotations", "argocd.argoproj.io/sync-options"], "Prune=false") }, "Prune=false·Delete=false"],
  ["locale 변경", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "bootstrap", "initdb", "localeCType"], "en_US.UTF-8") }, "locale은 C"],
  ["superuser 활성화", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "enableSuperuserAccess"], true) }, "superuser 계정을 활성화하지"],
  ["이미지 태그만", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "imageName"], "ghcr.io/persona-runtime/mafest-postgres:16.15-age1.6.0-bookworm") }, "digest 고정이 아니다"],
  ["세션 역할 누락", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "managed", "roles"], [YAML.load_stream(File.read(File.join(r, CLUSTER))).compact.first.dig("spec", "managed", "roles", 0)]) }, "mafest_session은 managed.roles"],
  ["세션 역할에 superuser", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "managed", "roles", 1, "superuser"], true) }, "mafest_session에 superuser"],
  ["세션 역할 비밀번호 Secret 변경", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "managed", "roles", 1, "passwordSecret", "name"], "mafest-db-runtime") }, "mafest_session은 managed.roles"],
  ["마이그레이션 역할 누락", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "managed", "roles"], YAML.load_stream(File.read(File.join(r, CLUSTER))).compact.first.dig("spec", "managed", "roles").first(2)) }, "mafest_session_migrator는 managed.roles"],
  ["마이그레이션 역할에 superuser", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "managed", "roles", 2, "superuser"], true) }, "mafest_session_migrator에 superuser"],
  ["마이그레이션 역할 비밀번호 Secret이 세션과 같음", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "managed", "roles", 2, "passwordSecret", "name"], "mafest-db-session") }, "mafest_session_migrator는 managed.roles"],
  ["runtime 역할에 superuser", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "managed", "roles", 0, "superuser"], true) }, "mafest_runtime에 superuser"],
  # 자리표시자 digest가 prod 렌더에 연결됨
  ["자리표시자 Cluster 이미지", ->(r) { mutate_yaml(File.join(r, CLUSTER), ["spec", "imageName"], "ghcr.io/persona-runtime/mafest-postgres:16.15-age1.6.0-bookworm@sha256:#{"0" * 64}") }, "자리표시자 digest(0×64)"],
  ["자리표시자 Job 연결", lambda { |r|
     mutate_yaml(File.join(r, STAGE), C0 + ["image"], "ghcr.io/persona-runtime/mafest-app@sha256:#{"0" * 64}")
     mutate_yaml(File.join(r, LOAD_K), ["resources"], ["job-stage.yaml"])
   }, "자리표시자 digest(0×64)"],
  ["Job 둘 동시 활성", ->(r) { mutate_yaml(File.join(r, LOAD_K), ["resources"], ["job-stage.yaml", "job-graph.yaml"]) }, "한 번에 하나만"],
  # Job 보안·자원
  ["Job backoffLimit 3", ->(r) { mutate_yaml(File.join(r, STAGE), ["spec", "backoffLimit"], 3) }, "backoffLimit 0"],
  ["Job restartPolicy OnFailure", ->(r) { mutate_yaml(File.join(r, GRAPH), POD + ["restartPolicy"], "OnFailure") }, "restartPolicy는 Never"],
  ["Job 쓰기 가능 루트", ->(r) { mutate_yaml(File.join(r, STAGE), C0 + ["securityContext", "readOnlyRootFilesystem"], false) }, "읽기 전용"],
  ["Job capability 유지", ->(r) { mutate_yaml(File.join(r, GRAPH), C0 + ["securityContext", "capabilities", "drop"], []) }, "capability는 모두 버린다"],
  ["Job stage limit 1Gi", ->(r) { mutate_yaml(File.join(r, STAGE), C0 + ["resources", "limits", "memory"], "1Gi") }, "기준선(512Mi"],
  ["Job /tmp 64Mi", ->(r) { mutate_yaml(File.join(r, STAGE), POD + ["volumes", 0, "emptyDir", "sizeLimit"], "64Mi") }, "256Mi 이상"],
  ["Job PGURL 평문", ->(r) { mutate_yaml(File.join(r, GRAPH), C0 + ["env", 0], { "name" => "PGURL", "value" => "postgresql://user@host/db" }) }, "PGURL은 Secret"],
  ["Job 라벨 변경", ->(r) { mutate_yaml(File.join(r, STAGE), ["spec", "template", "metadata", "labels", "app.kubernetes.io/name"], "loader") }, "mafest-loader가 아니면"],
  # NetworkPolicy·Namespace·Application
  ["default-deny 삭제", lambda { |r|
     path = File.join(r, NETPOL)
     docs = YAML.load_stream(File.read(path)).compact.reject { |d| d.dig("metadata", "name") == "mafest-default-deny" }
     File.write(path, docs.map { |d| YAML.dump(d) }.join)
   }, "mafest-default-deny가 있어야"],
  ["allow 모두 삭제", lambda { |r|
     path = File.join(r, NETPOL)
     docs = YAML.load_stream(File.read(path)).compact.select { |d| d.dig("metadata", "name") == "mafest-default-deny" }
     File.write(path, docs.map { |d| YAML.dump(d) }.join)
     File.write(File.join(r, "kustomize/base/networkpolicy/mafest-data/kustomization.yaml"), YAML.dump("apiVersion" => "kustomize.config.k8s.io/v1beta1", "kind" => "Kustomization", "resources" => ["network-policy.yaml"]))
   }, "allow가 없으면"],
  ["Namespace를 overlay에", lambda { |r|
     File.write(File.join(r, "kustomize/overlays/prod/mafest-db/namespace.yaml"), YAML.dump("apiVersion" => "v1", "kind" => "Namespace", "metadata" => { "name" => "mafest-data" }))
     mutate_yaml(File.join(r, "kustomize/overlays/prod/mafest-db/kustomization.yaml"), ["resources"], ["../../../base/mafest-db", "namespace.yaml"])
   }, "Namespace가 있다"],
  ["Application 자동 Sync", ->(r) { mutate_yaml(File.join(r, "argocd/mafest-db.yaml"), ["spec", "syncPolicy"], { "automated" => { "prune" => true } }) }, "자동 Sync"],
  ["Application finalizer", ->(r) { mutate_yaml(File.join(r, "argocd/mafest-db-netpol.yaml"), ["metadata", "finalizers"], ["resources-finalizer.argocd.argoproj.io"]) }, "finalizers를 두지 않는다"],
  # 권한 SQL
  ["runtime INSERT 권한", ->(r) { File.write(File.join(r, ROLES), File.read(File.join(r, ROLES)) + "\nGRANT INSERT ON ALL TABLES IN SCHEMA public TO mafest_runtime;\n") }, "쓰기 권한"],
  ["세션 역할 CONNECT 누락", ->(r) { File.write(File.join(r, ROLES), File.read(File.join(r, ROLES)).sub("GRANT CONNECT ON DATABASE mafest TO mafest_session;", "")) }, "mafest_session은 DB CONNECT"],
  ["세션 역할 테이블 권한을 SQL로", ->(r) { File.write(File.join(r, ROLES), File.read(File.join(r, ROLES)) + "\nGRANT SELECT ON ALL TABLES IN SCHEMA mafest_confirm TO mafest_session;\n") }, "마이그레이션 CLI --app-role"],
  ["마이그레이션 역할 CREATE 누락", ->(r) { File.write(File.join(r, ROLES), File.read(File.join(r, ROLES)).sub("GRANT CONNECT, CREATE ON DATABASE mafest TO mafest_session_migrator;", "")) }, "DB CONNECT·CREATE만"],
  ["마이그레이션 역할에 기본 권한", ->(r) { File.write(File.join(r, ROLES), File.read(File.join(r, ROLES)) + "\nALTER DEFAULT PRIVILEGES FOR ROLE mafest_session_migrator GRANT SELECT ON TABLES TO mafest_runtime;\n") }, "ALTER DEFAULT PRIVILEGES를 두지 않는다"],
  ["owner 로 세션 스키마 생성", ->(r) { File.write(File.join(r, ROLES), File.read(File.join(r, ROLES)) + "\nCREATE SCHEMA IF NOT EXISTS mafest_confirm AUTHORIZATION mafest_owner;\n") }, "owner 로 세션 스키마를 만들지 않는다"],
  ["유효 권한 SQL에서 runtime 격리 검사 삭제", ->(r) { File.write(File.join(r, SESSION_CHECK), File.read(File.join(r, SESSION_CHECK)).gsub("isolated-schema", "x-schema")) }, "isolated-schema 검사가 없다"],
  ["유효 권한 SQL에서 ROLLBACK 삭제", ->(r) { File.write(File.join(r, SESSION_CHECK), File.read(File.join(r, SESSION_CHECK)).gsub("ROLLBACK;", "COMMIT;")) }, "BEGIN READ ONLY와 ROLLBACK"],
  ["사전 점검 SQL에 소유권 변경", ->(r) { File.write(File.join(r, SESSION_PRECHECK), File.read(File.join(r, SESSION_PRECHECK)).sub("ROLLBACK;", "ALTER SCHEMA mafest_confirm OWNER TO mafest_session_migrator;\nROLLBACK;")) }, "변경문"],
  ["exporter CONNECT 누락", ->(r) { File.write(File.join(r, ROLES), File.read(File.join(r, ROLES)).sub(", cnpg_metrics_exporter;", ";")) }, "cnpg_metrics_exporter CONNECT"],
  ["ag_catalog USAGE 누락", ->(r) { File.write(File.join(r, ROLES), File.read(File.join(r, ROLES)).sub("GRANT USAGE ON SCHEMA ag_catalog TO mafest_owner, mafest_runtime;", "")) }, "ag_catalog USAGE"],
]

snapshot = lambda do
  Dir.glob(File.join(root, "{kustomize,argocd,bootstrap,db}/**/*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }
     .map { |f| [f, File.binread(f)] }.to_h
end
pristine = snapshot.call

cases.each do |label, mutate, message|
  begin
    mutate.call(root)
    output_path = File.join(root, "result.log")
    success = system("sh", File.join(root, "scripts/validate-mafest-data-manifests.sh"), out: output_path, err: [:child, :out])
    raise "회귀 검사가 결함을 놓쳤다: #{label}" if success
    raise "예상과 다른 검사 오류다(#{label}): 기대 '#{message}'\n#{File.read(output_path)}" unless File.read(output_path).include?(message)
    puts "검출: #{label}"
  ensure
    # 사례가 만든 파일은 지우고, 바꾼 파일은 원래 내용으로 되돌린다.
    (snapshot.call.keys - pristine.keys).each { |f| File.delete(f) }
    pristine.each { |f, body| File.binwrite(f, body) unless File.exist?(f) && File.binread(f) == body }
  end
end
puts "mafest 데이터 층 음성 테스트 #{cases.length}건 통과"
RUBY
