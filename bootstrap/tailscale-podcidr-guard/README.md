# Tailscale Pod 대역 경로 차단

노드의 tailscaled가 Pod 대역(`10.244.0.0/16`) 주소를 peer 연결 경로로 고르지 못하게, 노드에서
`UDP 41641`의 Pod 대역 왕복을 버린다. 규칙은 별도 nft 테이블 `inet tailscale_podcidr_guard`에 둔다.

## 원인과 증거 (2026-10-20 관측)

- 증상: B0 성능 재전송 중 mafest-api(worker2) → vLLM(persona-gpu-01) 스트리밍 응답이 1~2분 멈췄다.
  동시 4에서 120초 timeout 4건, 동시 8에서 토큰 90개가 30초 뒤 한꺼번에 도착했다.
- vLLM 로그: 정지 구간에 `Running: 0 reqs`. 엔진은 생성을 끝냈고 전달이 막혔다.
- worker2 tailscaled 로그: GPU 노드 peer 경로가 `10.244.5.57:41641` ↔ `43.203.20.16:41641`(GPU 노드
  공인 IP) 사이를 6~7초마다 바꿨다. 구간(UTC)은 01:14:30~01:17:02, 01:20:54~01:21:01이며 정지 구간과 겹친다.
- `kubectl get ciliumnode persona-gpu-01`의 CiliumInternalIP는 `10.244.5.57`, 즉 GPU 노드 `cilium_host` 주소다.
- worker2의 `ip route get 10.244.5.57`은 `dev cilium_host ... mtu 1230`. Pod 대역으로 가는 길은 Cilium
  VXLAN이고, 그 VXLAN은 Tailscale 위를 지난다.
- 72시간 동안 `now using 10.244.` 횟수는 worker2 42회, worker1 18회였다. 부하 때만이 아니라 반복된다.

**해석(추정)**: GPU 노드 tailscaled가 로컬 인터페이스 주소(`cilium_host` 포함)를 연결 후보로 알리고,
상대 노드의 탐색 패킷이 Cilium 오버레이를 타고 도착해 그 경로가 채택된다. 오버레이가 Tailscale 위에 있어
Tailscale 패킷이 자기 터널로 다시 들어가는 순환이 되고, 경로가 깨져 공인 IP로 돌아가기를 반복한다.
이 해석은 적용 뒤 로그로 검증한다(아래 4절).

## 방법을 고른 이유

| 후보 | 결과 |
| --- | --- |
| Tailscale 설정으로 인터페이스·대역 제외 | **지원이 없다.** [tailscale/tailscale#1552](https://github.com/tailscale/tailscale/issues/1552)는 열려 있고 `TS_AVOID_PREFIX` 등을 넣는 PR(#17762)은 반영되지 않았다. 인터페이스 이름(`cilium*`, `cali*`)을 빼는 [PR #8682](https://github.com/tailscale/tailscale/pull/8682)도 머지되지 않았다. 공식 문서에서도 해당 설정을 찾지 못했다(1.102.x 릴리스 노트 전수 검토는 하지 않았다) |
| debug 환경변수 | 공식 지원이 아니고 `TS_DISABLE_SRC_VALID_MARK`가 1.102.2에서 무효였던 전례가 있어 쓰지 않는다 |
| **노드 방화벽으로 Pod 대역 왕복 UDP 41641 차단** | **채택.** 이슈 #1552에서 쓰는 우회와 같다. 탐색이 실패하니 Pod 대역 경로가 채택되지 않는다 |
| Cilium 라우팅·MTU·터널 끝점, Tailscale 재등록·ACL·subnet route | 범위 밖이라 바꾸지 않는다 |

## Cilium 체인과의 순서

Cilium·kube-proxy 규칙은 `iptables-nft`가 만든 `ip filter`·`ip nat` 테이블에 있다. 이 규칙은 **다른 테이블**의
base chain(`inet tailscale_podcidr_guard`)에서 drop하므로 그쪽 체인의 ACCEPT와 무관하게 적용된다.
그래도 실제 노드 구성은 사용자가 확인해야 한다(아래 1절 명령).

차단하지 않는 것: Cilium VXLAN(`UDP 8472`, Tailnet IP끼리), DERP·공인 경로(목적지가 Pod 대역이 아님),
노드에서 Pod로 가는 헬스체크(`UDP 41641`이 아님), Pod 사이 트래픽(forward 훅이라 대상이 아님).

## 파일

| 파일 | 역할 |
| --- | --- |
| `rules.nft.in` | 규칙 원본. `@TS_PORT@`, `@POD_CIDR@` 자리표시자. 머리말에 왜 막는지 있다 |
| `tailscale-podcidr-guard.service` | 부팅 때 규칙을 올리는 oneshot unit(`Before=tailscaled.service`) |
| `tailscale-podcidr-guard.sh` | 홈 노드용 `apply`·`status`·`remove` |
| `../../ansible/gpu-node/playbooks/25-tailscale-podcidr-guard.yml` | GPU 노드용. 같은 두 파일을 쓴다 |

## 1. 적용 전 확인 (각 노드, 읽기만)

```bash
# 이전 24시간 횟수를 기록한다
journalctl -u tailscaled --since "24 hours ago" --no-pager | grep -c "now using 10.244."
# tailscaled UDP 포트. 41641이 아니면 TS_PORT로 그 값을 넘긴다
sudo ss -ulnp | grep tailscaled
# 기존 규칙 구성. nftables.service가 켜져 있거나 flush ruleset이 있으면 알려 준다
sudo nft list ruleset | head -60
sudo iptables -S OUTPUT
systemctl is-enabled nftables 2>/dev/null; command -v nft
```

`nft` 명령이 없으면 스크립트와 playbook이 멈춘다. nftables 패키지를 설치하면 `nftables.service`가
켜져 `/etc/nftables.conf`의 `flush ruleset`이 Cilium 규칙을 지울 수 있어 자동으로 설치하지 않는다.

## 2. 적용

홈 노드(worker2 먼저, 확인 뒤 나머지):

```bash
# 이 저장소의 bootstrap/tailscale-podcidr-guard/ 디렉터리를 노드로 복사한 뒤
sudo ./tailscale-podcidr-guard.sh apply          # 포트가 다르면 sudo TS_PORT=<포트> ./... apply
sudo ./tailscale-podcidr-guard.sh status
```

GPU 노드(로컬 inventory 사용. 먼저 `--check --diff`로 무엇이 바뀌는지 본다):

```bash
cd ansible/gpu-node
ansible-playbook -i <로컬 inventory> playbooks/25-tailscale-podcidr-guard.yml --check --diff
ansible-playbook -i <로컬 inventory> playbooks/25-tailscale-podcidr-guard.yml
```

이 절차는 Cilium·tailscaled를 재시작하지 않는다. 규칙은 재부팅, tailscaled 재시작, Cilium 재시작 뒤에도 남는다.

## 3. 적용 직후 확인

```bash
# GPU 노드 peer의 CurAddr가 공인 IP 그대로인지 (worker2에서)
tailscale status --json | jq '.Peer[] | select(.HostName=="persona-gpu-01") | {CurAddr, Relay}'
# 노드↔Pod 통신. context를 항상 명시한다
ping -c 3 <GPU 노드 Tailnet IP>
kubectl --context <context> -n persona-inference exec <pod> -- true
# 규칙 카운터가 오르는지: 탐색 패킷을 실제로 막고 있다는 증거
sudo nft list table inet tailscale_podcidr_guard
```

## 4. 효과 검증

1. 부하 재현: B0 재전송 `--modes 4,8`.
2. 같은 시간대 tailscaled 로그에서 `grep -c "now using 10.244."`가 0회인지, 120초 timeout이 없는지.
3. 24시간 뒤 1절의 횟수 명령을 다시 실행해 0회인지 확인한다.

0회가 아니면 이 해석(Pod 대역 경로 채택이 원인)이나 규칙 위치가 맞지 않는 것이다. `status`의 포트 경고와
`nft list ruleset`의 hook 순서를 먼저 확인한다.

## 5. 되돌리기

```bash
sudo ./tailscale-podcidr-guard.sh remove          # 홈 노드
sudo systemctl disable --now tailscale-podcidr-guard.service && sudo nft delete table inet tailscale_podcidr_guard   # GPU 노드 (파일은 /etc/tailscale-podcidr-guard, /etc/systemd/system 아래)
```

즉시 풀어야 하면 `sudo nft delete table inet tailscale_podcidr_guard` 한 줄이면 규칙이 사라진다
(unit이 켜져 있으면 다음 부팅에 다시 올라오므로 위 명령으로 unit도 끈다).
