#!/bin/sh

set -eu

# kustomize/base/observability/alerts의 PrometheusRule을 promtool로 검사한다. 클러스터를 호출하지 않는다.
#   1) check rules: 문법과 PromQL
#   2) test rules: scripts/promtool/alert-rules.test.yaml의 합성 시계열로 발화·미발화
# promtool이 없으면 docker의 prom/prometheus 이미지를 쓴다. 둘 다 없으면 검사하지 못한 것이므로 실패로 끝낸다.
#
# 시험은 규칙의 expr만 본다. annotations 문구는 시험에 박지 않으려고 시험용 복사본에서 뺀다.

for tool in kubectl ruby mktemp; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "필요한 도구가 없습니다: ${tool}" >&2
    exit 1
  fi
done

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/alert-rules.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

kubectl kustomize "$repo_dir/kustomize/base/observability/alerts" > "$work_dir/rendered.yaml"

# PrometheusRule 리소스는 spec.groups만 promtool이 읽는 형식이다.
ruby -ryaml -e '
  doc = YAML.load_stream(File.read(ARGV[0])).find { |d| d && d["kind"] == "PrometheusRule" } ||
    abort("[안전] PrometheusRule이 렌더에 없다")
  groups = doc.fetch("spec").fetch("groups")
  File.write(ARGV[1], YAML.dump({ "groups" => groups }))
  stripped = groups.map { |g| g.merge("rules" => g["rules"].map { |r| r.reject { |k, _| k == "annotations" } }) }
  File.write(ARGV[2], YAML.dump({ "groups" => stripped }))
' "$work_dir/rendered.yaml" "$work_dir/full.yaml" "$work_dir/rules.yaml"

cp "$repo_dir/scripts/promtool/alert-rules.test.yaml" "$work_dir/alert-rules.test.yaml"

if command -v promtool > /dev/null 2>&1; then
  promtool check rules "$work_dir/full.yaml"
  (cd "$work_dir" && promtool test rules alert-rules.test.yaml)
elif command -v docker > /dev/null 2>&1; then
  docker run --rm -v "$work_dir":/w -w /w --entrypoint promtool prom/prometheus:v3.5.0 check rules full.yaml
  docker run --rm -v "$work_dir":/w -w /w --entrypoint promtool prom/prometheus:v3.5.0 test rules alert-rules.test.yaml
else
  echo "promtool도 docker도 없어 규칙을 검사하지 못했습니다" >&2
  exit 1
fi

echo "알림 규칙 검사 통과"
