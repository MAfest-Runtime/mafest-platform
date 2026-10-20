#!/bin/sh
# 홈 노드용: Tailscale이 Pod 대역 주소를 연결 경로로 고르지 못하게 막는 nft 규칙을 적용·확인·되돌린다.
#
#   sudo ./tailscale-podcidr-guard.sh apply     # 규칙·unit 설치, 부팅 때 자동 적용
#   sudo ./tailscale-podcidr-guard.sh status    # 읽기만 한다
#   sudo ./tailscale-podcidr-guard.sh remove    # 규칙·unit 제거(되돌리기)
#
# 왜 막는지는 rules.nft.in 머리말에 있다. 이 스크립트는 같은 디렉터리의 rules.nft.in과
# tailscale-podcidr-guard.service를 원본으로 쓴다(GPU 노드 Ansible도 같은 파일을 쓴다).
#
# apply는 몇 번 실행해도 결과가 같다: 파일이 같으면 쓰지 않고, 규칙은 테이블째 다시 만든다.
# 이 스크립트는 Cilium·Tailscale·kubelet을 재시작하지 않는다.
#
# 환경변수: TS_PORT(기본 41641), POD_CIDR(기본 10.244.0.0/16).
# 시험용: GUARD_ETC_DIR, GUARD_UNIT_DIR, GUARD_SKIP_ROOT_CHECK=1.
set -eu

TS_PORT=${TS_PORT:-41641}
POD_CIDR=${POD_CIDR:-10.244.0.0/16}
ETC_DIR=${GUARD_ETC_DIR:-/etc/tailscale-podcidr-guard}
UNIT_DIR=${GUARD_UNIT_DIR:-/etc/systemd/system}
TABLE=tailscale_podcidr_guard
UNIT=tailscale-podcidr-guard.service
SRC_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

die() { echo "오류: $*" >&2; exit 1; }

# 값이 규칙 파일에 그대로 들어가므로 형식을 먼저 확인한다.
validate_inputs() {
  case $TS_PORT in
    ''|*[!0-9]*) die "TS_PORT는 숫자여야 한다: $TS_PORT" ;;
  esac
  case $POD_CIDR in
    *[!0-9./]*|'') die "POD_CIDR 형식이 잘못됐다: $POD_CIDR" ;;
  esac
}

need_root_and_tools() {
  [ "${GUARD_SKIP_ROOT_CHECK:-0}" = 1 ] || [ "$(id -u)" -eq 0 ] || die "root로 실행한다(sudo)."
  # nftables 패키지를 새로 설치하지 않는다. 설치하면 nftables.service가 켜져
  # /etc/nftables.conf의 `flush ruleset`이 Cilium 규칙을 지울 수 있다.
  command -v nft >/dev/null 2>&1 || die "nft 명령이 없다. 이 스크립트는 패키지를 설치하지 않는다."
  command -v systemctl >/dev/null 2>&1 || die "systemctl이 없다."
}

render_rules() {
  sed -e "s|@TS_PORT@|$TS_PORT|g" -e "s|@POD_CIDR@|$POD_CIDR|g" "$SRC_DIR/rules.nft.in"
}

# 내용이 다를 때만 쓴다. 바뀌었으면 0, 같으면 1을 돌려준다.
install_if_changed() {
  src=$1
  dest=$2
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 1
  fi
  cp "$src" "$dest"
  chmod 0644 "$dest"
  return 0
}

cmd_apply() {
  validate_inputs
  need_root_and_tools
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT HUP INT TERM
  render_rules >"$tmp/rules.nft"
  # 잘못된 규칙을 설치하기 전에 문법을 본다(커널에는 반영하지 않는다).
  nft -c -f "$tmp/rules.nft" || die "규칙 문법 검사에 실패했다."

  mkdir -p "$ETC_DIR" "$UNIT_DIR"
  rules_changed=0
  unit_changed=0
  install_if_changed "$tmp/rules.nft" "$ETC_DIR/rules.nft" && rules_changed=1
  install_if_changed "$SRC_DIR/$UNIT" "$UNIT_DIR/$UNIT" && unit_changed=1

  [ "$unit_changed" -eq 0 ] || systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null
  if systemctl is-active --quiet "$UNIT"; then
    # 이미 켜져 있으면 규칙 파일이 바뀐 때만 다시 읽는다.
    [ "$rules_changed" -eq 0 ] || systemctl reload "$UNIT"
  else
    systemctl start "$UNIT"
  fi
  echo "적용 완료: 포트 $TS_PORT, 대역 $POD_CIDR (규칙 변경=$rules_changed, unit 변경=$unit_changed)"
}

cmd_status() {
  need_root_and_tools
  ok=1
  if [ -f "$ETC_DIR/rules.nft" ]; then echo "규칙 파일: 있음"; else echo "규칙 파일: 없음"; ok=0; fi
  if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then echo "unit 부팅 자동 적용: 켜짐"; else echo "unit 부팅 자동 적용: 꺼짐"; ok=0; fi
  if nft list table inet "$TABLE" >/dev/null 2>&1; then
    echo "커널 규칙: 있음 (counter가 오르면 탐색 패킷을 실제로 막고 있는 것이다)"
    nft list table inet "$TABLE"
  else
    echo "커널 규칙: 없음"
    ok=0
  fi
  # tailscaled가 실제로 쓰는 UDP 포트가 설정과 같은지 읽기만 한다.
  if command -v ss >/dev/null 2>&1; then
    listen=$(ss -H -ulnp 2>/dev/null | grep tailscaled | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ')
    echo "tailscaled UDP 수신 포트: ${listen:-확인 불가}"
    case " $listen " in
      *" $TS_PORT "*|'  ') : ;;
      *) echo "경고: tailscaled 포트가 설정($TS_PORT)과 다르다. TS_PORT를 맞춰 다시 apply한다."; ok=0 ;;
    esac
  fi
  [ "$ok" -eq 1 ]
}

cmd_remove() {
  need_root_and_tools
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  # stop이 테이블을 지우지만 unit이 이미 없던 경우를 위해 한 번 더 지운다.
  nft delete table inet "$TABLE" >/dev/null 2>&1 || true
  rm -f "$ETC_DIR/rules.nft" "$UNIT_DIR/$UNIT"
  rmdir "$ETC_DIR" 2>/dev/null || true
  systemctl daemon-reload
  echo "제거 완료"
}

case ${1:-} in
  apply) cmd_apply ;;
  status) cmd_status ;;
  remove) cmd_remove ;;
  *) echo "사용법: $0 apply|status|remove" >&2; exit 2 ;;
esac
