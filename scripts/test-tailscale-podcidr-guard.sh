#!/bin/sh
# tailscale-podcidr-guard.sh가 몇 번 적용해도 규칙이 한 벌이고, 되돌리면 모두 사라지는지 확인한다.
#
# 가짜 nft·systemctl을 PATH 앞에 두고 임시 디렉터리에서만 돌린다. 실제 nft 규칙, systemd,
# 클러스터는 건드리지 않는다. 규칙 문법 자체는 실제 nft가 있을 때 별도로 `nft -c -f`로 본다.
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
guard_dir="$repo_dir/bootstrap/tailscale-podcidr-guard"
work=$(mktemp -d "${TMPDIR:-/tmp}/podcidr-guard.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

mkdir -p "$work/bin" "$work/etc" "$work/units"
state="$work/state"
: >"$state"

# 가짜 nft: -c(문법만)는 성공, delete는 상태에서 table을 빼고, -f는 table을 하나로 기록한다.
cat >"$work/bin/nft" <<'STUB'
#!/bin/sh
case "$1" in
  -c) exit 0 ;;
  delete) sed -i.bak '/table/d' "$GUARD_TEST_STATE"; exit 0 ;;
  list) grep -q table "$GUARD_TEST_STATE" || exit 1; echo "table inet tailscale_podcidr_guard"; exit 0 ;;
  -f) sed -i.bak '/table/d' "$GUARD_TEST_STATE"; echo table >>"$GUARD_TEST_STATE"; exit 0 ;;
esac
exit 0
STUB
# 가짜 systemctl: enable/disable 상태만 기록한다. is-active는 항상 거짓이라 start 경로를 탄다.
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/sh
case "$1" in
  is-active) exit 1 ;;
  is-enabled) [ -f "$GUARD_TEST_STATE.enabled" ] ;;
  enable) : >"$GUARD_TEST_STATE.enabled" ;;
  disable) rm -f "$GUARD_TEST_STATE.enabled" ;;
  start) sh -c "$GUARD_TEST_NFT -f x" ;;
esac
exit 0
STUB
chmod +x "$work/bin/nft" "$work/bin/systemctl"

export PATH="$work/bin:$PATH"
export GUARD_TEST_STATE="$state"
export GUARD_TEST_NFT="$work/bin/nft"
export GUARD_ETC_DIR="$work/etc"
export GUARD_UNIT_DIR="$work/units"
export GUARD_SKIP_ROOT_CHECK=1
guard="$guard_dir/tailscale-podcidr-guard.sh"

fail() { echo "실패: $*" >&2; exit 1; }
table_count() { grep -c table "$state" || true; }

# 1) 적용: 규칙 파일과 unit이 놓이고 자리표시자가 남지 않는다.
sh "$guard" apply >/dev/null
[ -f "$GUARD_ETC_DIR/rules.nft" ] || fail "규칙 파일이 없다"
[ -f "$GUARD_UNIT_DIR/tailscale-podcidr-guard.service" ] || fail "unit이 없다"
if grep -q '@' "$GUARD_ETC_DIR/rules.nft"; then fail "치환되지 않은 자리표시자가 남았다"; fi
grep -q 'udp sport 41641' "$GUARD_ETC_DIR/rules.nft" || fail "출력 규칙에 포트가 없다"

# 2) 멱등: 한 번 더 적용해도 결과가 같고 규칙은 한 벌이다.
before=$(cksum "$GUARD_ETC_DIR/rules.nft")
sh "$guard" apply >/dev/null
after=$(cksum "$GUARD_ETC_DIR/rules.nft")
[ "$before" = "$after" ] || fail "두 번째 적용에서 규칙 파일이 달라졌다"
[ "$(table_count)" -eq 1 ] || fail "규칙이 한 벌이 아니다"
[ "$(grep -c 'chain output' "$GUARD_ETC_DIR/rules.nft")" -eq 1 ] || fail "규칙 파일에 체인이 중복됐다"

# 3) 포트 지정: 다른 포트를 주면 그 값이 규칙에 반영된다.
TS_PORT=51820 sh "$guard" apply >/dev/null
grep -q 'udp sport 51820' "$GUARD_ETC_DIR/rules.nft" || fail "TS_PORT가 반영되지 않았다"

# 4) 잘못된 입력은 설치 전에 거부한다.
if TS_PORT='41641; flush ruleset' sh "$guard" apply >/dev/null 2>&1; then fail "잘못된 포트를 받아들였다"; fi

# 5) 되돌리기: 규칙과 파일이 모두 사라지고, 한 번 더 실행해도 실패하지 않는다.
sh "$guard" remove >/dev/null
[ ! -f "$GUARD_ETC_DIR/rules.nft" ] || fail "되돌린 뒤에도 규칙 파일이 남았다"
[ ! -f "$GUARD_UNIT_DIR/tailscale-podcidr-guard.service" ] || fail "되돌린 뒤에도 unit이 남았다"
[ "$(table_count)" -eq 0 ] || fail "되돌린 뒤에도 규칙이 남았다"
sh "$guard" remove >/dev/null || fail "두 번째 remove가 실패했다"

# 6) 원본 파일이 서로 맞는다: Ansible이 읽는 unit과 규칙 원본이 같은 디렉터리에 있다.
[ -f "$guard_dir/rules.nft.in" ] && [ -f "$guard_dir/tailscale-podcidr-guard.service" ] || fail "원본 파일이 없다"

echo "tailscale-podcidr-guard 시험 통과"
