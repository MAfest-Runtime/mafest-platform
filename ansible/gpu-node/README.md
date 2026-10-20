# GPU Node Ansible 골격

상태: **실행 전 골격**(2026-09-25 계층 재편). 이 디렉터리는 생성된 AWS GPU 호스트의 OS 전제,
GPU runtime, Tailscale 패키지, Join 전 확인까지 자동화한다. EC2 생성, tailnet 등록,
`kubeadm join`, Kubernetes 리소스 적용은 하지 않는다.

**실행한 적이 없다.** 이 저장소를 쓰는 개발 환경에 `ansible`이 설치돼 있지 않아
`--syntax-check`와 `ansible-lint`를 돌리지 못했다. YAML 파싱과 모듈 이름·인자만 수동으로
대조했다. 실제 host에 쓰기 전에 두 검사를 먼저 통과시킨다.

## 실행 경계

번호는 10 단위로 띄운다 — 나중에 한 계층을 둘로 쪼갤 때 전체를 다시 번호 붙이지 않는다.

| Playbook | 하는 일 | 하지 않는 일 |
| --- | --- | --- |
| `00-preflight.yml` | OS·architecture·디스크 여유·메모리·swap·시간 동기화·네트워크와 MTU·필수 binary 상태 **읽기** | 어떤 설정도 변경하지 않음 |
| `10-base.yml` | Kubernetes host 공통 전제(swap off, kernel module, sysctl)와 containerd·kubeadm·kubelet·kubectl 준비·hold | Tailscale 등록, Join, GPU driver 설치 |
| `20-tailscale.yml` | Tailscale **패키지 설치와 서비스 활성화까지만** | `tailscale up`, auth key 전달, route 광고·수락, SNAT 설정 |
| `25-tailscale-podcidr-guard.yml` | Pod 대역(`10.244.0.0/16`)과 오가는 Tailscale UDP 41641을 버리는 nft 규칙·unit 설치. 원인과 절차는 [bootstrap/tailscale-podcidr-guard](../../bootstrap/tailscale-podcidr-guard/README.md) | tailscaled·Cilium 재시작, Cilium 설정·MTU·ACL 변경, nftables 패키지 설치 |
| `30-gpu-runtime.yml` | R580 driver 판정(없으면 설치, 정상이면 건너뜀, 그 밖이면 중단)과 hold, Container Toolkit 설치, containerd runtime 등록, `nvidia-smi`로 GPU 1장·R580 기준선 확인 | container GPU 실행, device plugin 배포, taint 제거 |
| `40-join-preflight.yml` | Join 직전 binary·버전(API server 기준 skew 판정)·swap·containerd·API 포트·방화벽·token 존재 여부 **읽기** | `kubeadm join`, token·CA hash 수신·저장 |

## 계층을 이렇게 나눈 이유

- **driver와 Join을 떼어 놓는다.** driver는 kernel module이라 재부팅이 필요하다. 한 playbook에
  섞으면 재부팅 실패가 Kubernetes 등록 실패처럼 보인다.
- **Tailscale은 설치와 등록을 나눈다.** auth key는 한 번 쓰면 끝나는 단기 비밀이다. playbook에
  담으면 로그·`--diff`·셸 히스토리에 남고 되돌릴 수 없다. 등록은 사람이 host에서 직접 한다.
- **Join 전 확인을 별도 계층으로 둔다.** 읽기만 하므로 언제든 다시 돌릴 수 있고, "Join할 수
  있는 상태"와 "Join 성공"을 섞지 않는다.

## `--check`가 실제로 무엇을 검사하는가

`ansible.builtin.command`는 기본적으로 `--check`에서 **건너뛰어진다**. 그래서 읽기와 쓰기를
모두 `command`로 두면 `--check` 실행이 아무것도 검사하지 못한 채 통과로 보인다(이전 판의
`01-base.yml`이 그랬다 — swap·sysctl·module 경로를 하나도 확인하지 않았다).

지금은 이렇게 나눈다.

- **상태를 읽는 task**: `check_mode: false` + `changed_when: false` → `--check`에서도 실행된다.
  host를 바꾸지 않으므로 안전하다.
- **바꾸는 task**: 위에서 읽은 상태를 `when` 조건으로 삼는다 → 두 번째 실행에서 건너뛰고,
  `--check`에서는 "무엇이 바뀔지"가 실제 상태 기준으로 보인다.
- **검증**: `command` 결과가 아니라 `assert`로 판정한다 → `--check`에서도 발동한다.

예외로 `30-gpu-runtime.yml`의 NVIDIA Container Toolkit은 `--check`에서 설치를 보류한다.
NVIDIA APT 저장소 선언도 check mode에서는 파일로 쓰이지 않으므로, 그 직후 apt가 패키지를
찾지 못하는 오류를 설치 실패로 오해하지 않기 위해서다. 실제 실행은 저장소 등록·패키지
설치·containerd runtime 확인·GPU 확인을 같은 playbook에서 연속으로 수행한다.

## 멱등성

두 번째 실행에서 재부팅이나 driver 재설치가 일어나지 않는다.

- kernel module: `/proc/modules`를 읽어 **빠진 것만** `modprobe`
- sysctl: 선언 파일이 **바뀐 경우에만** `sysctl --system`, 실효값은 `assert`로 확인
- swap: `swaptotal_mb > 0`일 때만 `swapoff`
- driver: `files/nvidia_driver_gate.py`가 host 상태를 판정한다. R580이 이미 정상(요청 package
  version 설치 + 같은 version 적재 + 실행 중 kernel용 DKMS installed)이면 설치·재부팅 task가
  건너뛰어진다. driver가 없을 때만 설치하고 그때만 재부팅한다. 다른 branch·다른 patch·미적재·DKMS
  불일치는 아무것도 바꾸지 않고 멈춘다(자동 전환·재설치 없음)
- containerd 기본 설정: `creates:`로 이미 있으면 생성하지 않음

## 비밀 경계

inventory와 vars에는 공인 IP·SSH 사용자명만 둔다. 다음은 **어디에도** 넣지 않는다 —
inventory, vars, playbook, 출력, 셸 인자.

- Tailscale auth key → 사람이 host에서 `tailscale up` 실행 시 직접 입력
- kubeadm join token·CA hash → `40-join-preflight.yml`은 환경변수가 **비어 있지 않은지만**
  보고 값을 읽지 않는다. 유효성·만료도 확인하지 않는다(그건 Join 명령이 판정한다)
- AWS credential → 이 host는 AWS API를 부르지 않는다(instance IAM role도 없다)
- 모델 다운로드 토큰 → 모델 cache seed는 Kubernetes Job의 일이고 Ansible 범위가 아니다

## 현재 가능한 검사

```bash
# 먼저 ansible을 설치한 환경에서
ansible-playbook -i inventory.example.yml playbooks/00-preflight.yml --syntax-check
ansible-lint playbooks/

# 예시 inventory는 접속할 수 없는 합성 IP(TEST-NET-3)라 실행은 연결 단계에서 실패한다.
```

실제 실행은 EC2 생성 뒤 사용자가 만든 로컬 inventory로만 한다. 변경 playbook은 `--check`를
먼저 돌린 뒤 사람이 결과를 확인하고 실행한다.

## 실행 순서와 사람이 끼어드는 지점

```text
00-preflight  →  10-base  →  20-tailscale  →  [사람: tailscale up + route 승인]
              →  30-gpu-runtime  →  40-join-preflight  →  [사람: kubeadm join]
              →  [사람: device plugin 배포, nvidia.com/gpu 확인]  →  [사람: vLLM 배포]
```

`10-base`와 `30-gpu-runtime`은 실제 값을 넘겨야 동작한다. 비어 있으면 해당 단계를 건너뛰고
그 사실을 출력한다 — 추측한 패키지 버전으로 설치하지 않는다.

| 넘길 값 | 어디서 읽는가 |
| --- | --- |
| `gpu_kubernetes_minor` (예: `1.36`) | API server의 실제 minor(`10-base`) |
| `gpu_kubernetes_package_version` (예: `1.36.2-1.1`) | GPU host에 저장소를 등록한 뒤 `apt-cache madison kubeadm kubelet kubectl`이 보여 준 값(`10-base`). 비워서 한 번 실행하면 목록을 출력한다 |
| `api_server_version` (예: `v1.36.4`) | `kubectl version -o json`의 `serverVersion.gitVersion`(`10-base`는 package version을 넘길 때 필수, `40-join-preflight`는 항상 필수) |
| `control_plane_kubelet_version` (예: `v1.36.2`) | CP Node의 `status.nodeInfo.kubeletVersion`(`40-join-preflight`, 필수) |
| `nvidia_driver_package_version` (예: `580.95.05-0ubuntu0.24.04.2`) | GPU host의 `apt-cache madison nvidia-driver-580-server` 출력(`30-gpu-runtime`). 비우면 현재 상태와 후보만 출력하고 멈춘다. branch는 R580 고정이며 `nvidia_driver_branch=570` 같은 이전 입력은 거부한다 |
| `nvidia_container_toolkit_version` | NVIDIA 저장소의 실제 패키지 버전(네 패키지 동일) |
| `control_plane_api_host` | CP의 LAN 주소 |

## 버전 입력의 의미와 Join 판정

세 종류의 버전은 서로 다른 것을 가리킨다. 한 값으로 다른 값을 대신하지 않는다.

| 이름 | 무엇인가 | 형식 | 판정에서의 역할 |
| --- | --- | --- | --- |
| API server version | 클러스터 kube-apiserver가 실제로 실행 중인 버전 | `v1.36.4` | **기준.** kubelet은 이보다 새 버전이면 안 되고, kubeadm·kubelet minor는 이와 같아야 한다 |
| CP kubelet version | control-plane Node의 kubelet 버전 | `v1.36.2` | 기록만 한다. API server와 patch가 다를 수 있어(위 예시가 그 상태다) 비교 기준으로 쓰지 않는다 |
| GPU package version | GPU host에 설치할 kubeadm·kubelet·kubectl deb version | `1.36.2-1.1` | 설치 **전에** minor = API server, patch ≤ API server patch를 확인하고, 저장소 목록에 있는 값만 받아 세 패키지를 같은 값으로 고정 설치하고 hold한다 |

`10-base`의 설치 전 판정(`files/kube_version_gate.py package`): package minor가 `gpu_kubernetes_minor`·
API server와 같고 package patch가 API server patch 이하일 때만 설치한다. 예를 들어 API server가
v1.36.4일 때 저장소에 `1.36.4-*`가 있으면 그것을, 없고 `1.36.2-*`만 있으면 그것을 고를 수 있다.
`1.36.5` 이상만 있으면 설치하지 않고 멈춘다 — Join 직전 판정까지 가서 막으면 이미 host에 설치된
뒤이기 때문이다.

`40-join-preflight`의 판정(`files/kube_version_gate.py join`):

- **실패**: GPU kubeadm 또는 kubelet의 major.minor가 API server와 다르다. GPU kubelet patch가 API
  server patch보다 크다. 입력 형식이 `vMAJOR.MINOR.PATCH`가 아니다(pre-release는 받지 않는다).
- **drift(통과, 출력만)**: CP kubelet ≠ API server, GPU kubelet ≠ CP kubelet, GPU kubeadm ≠ GPU kubelet.
- 통과·실패와 무관하게 네 버전(API server, CP kubelet, GPU kubeadm, GPU kubelet)과 patch를 모두
  출력한다. 이전 판은 CP kubelet 문자열이 출력에 포함되는지만 봐서 기준이 틀렸고 `v1.36.2`가
  `v1.36.21`에도 걸렸다.

위 예시 값(API server v1.36.4, CP kubeadm·kubelet v1.36.2)은 2026-09-26 관측값이다. 실행할 때마다
다시 읽는다. 이 playbook은 control plane을 업그레이드하지 않는다.

판정 스크립트(`files/kube_version_gate.py`, `files/nvidia_driver_gate.py`) 테스트(표준 라이브러리만, 네트워크·클러스터·host 없음):

```sh
python3 -m unittest discover -s ansible/gpu-node/tests -v
```

## 아직 만들지 않은 것

`ansible.cfg`와 `requirements.yml`은 만들지 않았다. 실행 환경이 없는 상태에서 collection을
고정하면 검증되지 않은 의존성 목록이 생긴다. 지금 playbook은 `ansible.builtin`만 쓰므로
collection 추가 없이 동작한다 — `community.general.modprobe`·`ansible.posix.sysctl` 같은
편한 모듈을 쓰지 않은 이유가 그것이다.
