# AWS GPU 랩 기반 — 생성 기록과 라우터 준비

> **2026-10-01 확인:** 복원된 이 worktree의 로컬 Terraform state에는 GPU VPC,
> `ap-northeast-2a` GPU 인스턴스와 EIP가 등록돼 있다. 이후 실제 AWS refresh plan에서도
> 변경 없음을 확인했다. 아래 2026-09-19·09-25의 "생성 전" 문구와 준비 상태표는 당시 기록이며
> 현재 미배포를 뜻하지 않는다. 새 site-to-site 라우터의 코드·검증·적용 경계는
> AWS 라우터 단계 계획(Git 이력)을 따른다. 2026-10-01 라우터 EC2와
> 전용 서브넷·보안 그룹을 생성했다. 두 전용 라우터의 Tailscale 시험망은 양방향
> ICMP 각 100/100을 확인했지만 기존 GPU·Kubernetes 경로 전환은 수행하지 않았다.
> 코드의 기본값은 `router_enabled=false`다. 현재 환경의 비공개 `terraform.tfvars`에는
> `true`와 임시 관리자 SSH `/32`를 유지하며, 이후 일반 plan에서 삭제가 계획되지 않게 한다.

## 전용 라우터 경로용 비공개 시험 EC2

`site_probe_enabled`는 기본 `false`다. 현재 환경에서 시험할 때만 비공개
`terraform.tfvars` 또는 `TF_VAR_site_probe_enabled=true`로 활성화한다.
`router_enabled=true`도 함께 유지해야 한다. 두 값이 모두 true일 때만 GPU와 같은
서브넷에 `t3.micro` 시험 EC2, 전용 보안 그룹, AWS 라우터 보안 그룹에서만 허용하는
사설 SSH 규칙을 만든다. 공인 IPv4, Tailscale, Kubernetes, 자동 부트스트랩은 없다.
첫 생성 단계에서는 GPU 서브넷 라우트 테이블이나 기존 노드 경로를 바꾸지 않았다.
사설 EC2이므로 인터넷에서 직접 SSH하거나 패키지를 설치할 수 있다고 가정하지 않는다.

2026-10-01 실제 계정 plan에서 시험 EC2·보안 그룹·SSH 규칙만 추가되고
기존 자원 변경·삭제가 0임을 확인했다(`3 to add, 0 to change, 0 to destroy`).
그 plan을 적용했고 시험 EC2의 사설 주소는 `10.80.0.58`이다. Mac에서 AWS 라우터를
경유한 SSH도 확인했다. 홈 라우터는 이 주소를 `tailscale0`로 보낸다.

다음 단계 코드는 GPU 서브넷 라우트 테이블에 **`172.29.250.2/32`만** AWS 라우터 ENI로
보내는 경로를 추가한다. 시험 EC2와 라우터의 ICMP 규칙도 이 시험 주소와 시험 EC2
사설 주소로만 제한한다. AWS 라우터의 `source_dest_check=false`, 홈·AWS 라우터의
IP forwarding, Tailnet 경로 승인·수신이 전제다. 이 변경을 적용해도 기존 GPU·Kubernetes
Node InternalIP나 실제 홈 LAN `192.168.50.0/24`의 경로는 전환하지 않는다.
2026-10-01 실제 계정 plan에서 `172.29.250.2/32` 경로가 GPU 서브넷 라우트 테이블
`rtb-07435e3f8b89d2dcd`에서 AWS 라우터 ENI `eni-06195cd88a0ce9dd3`로 향하고,
ICMP 규칙 세 개만 추가됨을 확인했다(`4 to add, 0 to change, 0 to destroy`).
저장된 `site-probe-route.tfplan`은 민감한 state 정보를 포함할 수 있어 Git·채팅에
올리지 않는다. 적용 후 `TF_VAR_site_probe_enabled=true terraform plan`에서
**변경 없음**을 확인했다. 시험 EC2 → 홈 시험 주소는 ICMP 100/100 응답·평균
4.225ms, 홈 시험 주소 → 시험 EC2도 100/100 응답·평균 4.708ms였다. 측정 직후
AWS 라우터의 Tailscale 상태는 홈 라우터와 `direct`였다.
1200바이트 ICMP payload에 DF를 설정한 시험도 100/100 응답·평균 4.617ms였다.
이 결과는 해당 크기의 패킷 통과만 확인한다. 손실률·지연의 장기 보장이나 기존
경로 대비 성능 개선으로 해석하지 않는다. 실제 GPU·Pod의 VXLAN/HTTP 경로
검증도 별도로 필요하다.
시험 중에는 매번 `TF_VAR_site_probe_enabled=true`를 유지해야 한다. 생략하면 기본값
`false`에 따라 시험 EC2와 시험 경로의 삭제 계획이 나올 수 있다.
시험 EC2와 gp3 디스크는 실행·중지 상태에 따라 비용이 발생한다. 적용과 제거는
각각 별도의 계획 검토를 거친다.

### TCP/HTTP 시험 준비

ICMP 다음으로 시험 EC2에서 홈 시험 주소 `172.29.250.2/32`의 TCP 8080으로만
요청을 보낼 수 있도록 egress 규칙을 추가했다. 중간 AWS 라우터에도 시험 EC2
`10.80.0.58/32`에서 들어오는 TCP 8080만 허용한다. 시험 EC2의 HTTP ingress나
실제 홈 LAN·GPU 서비스 포트는 열지 않는다. 2026-10-01 실제 계정 plan에서
규칙 두 개만 추가되고 기존 자원 변경·삭제는 0개임을 확인했다.
저장된 `site-probe-http.tfplan`을 적용했고, 결과는 2개 추가·변경 0개·삭제 0개였다.
홈 시험 namespace의 빈 임시 디렉터리를 제공하는 HTTP 서버에 시험 EC2에서
GET을 100회 보냈고 모두 `200`이었다(평균 0.0090초, 최대 0.0242초).
이것은 작은 정적 응답의 연결 검증이며 실제 서비스 처리량·장기 가용성이나
기존 경로 대비 성능 개선을 의미하지 않는다. HTTP 테스트를 마치면 임시 서버를
종료하고 빈 디렉터리를 제거한다.

2026-09-19: Terraform·노드 Join 계획 작성 단계. AWS 리소스 생성·실제 plan·K8s 조인 완료가 아니다.
기존 `envs/prod` 경로를 사용하지만 상용 HA 환경이 아닌 단일 GPU 실험 환경이다.

## 만드는 범위

- 서울 전용 VPC, 퍼블릭 서브넷 하나(/16 VPC의 첫 /24), Internet Gateway, 기본 경로.
- On-Demand `g6.xlarge` 한 대(4 vCPU·16 GiB RAM·NVIDIA L4 1장, EC2 사양표 기준 가용 GPU 메모리 22 GiB), 암호화 gp3 루트 디스크 100 GiB·3000 IOPS·125 MiB/s.
- EC2 primary network interface에 고정 Elastic IP(EIP) 하나. NAT Gateway, Load Balancer는 만들지 않는다.
- IMDSv2 필수, hop limit 1. AWS API가 필요 없는 호스트이므로 instance IAM role/profile은 만들지 않는다.
- 초기 SSH용 공개 키만 등록. 개인 키·AWS 키·Tailscale 인증 키·kubeadm 토큰은 코드/state/user-data에 넣지 않는다.
- SSH는 기본 닫힘. 최초 접속용 관리자 공인 IPv4 `/32`를 명시하면 TCP 22만 임시 허용한다.
- UDP 41641은 선택한 Tailscale 피어의 **공인 IPv4 `/32`**에만 선택적으로 허용한다. 기본 목록은 비어 있고 그대로 두는 것을 우선한다.
- vLLM 8000, Kubernetes API 6443, kubelet 10250, VXLAN 8472, NodePort 등은 공개 인바운드에 추가하지 않는다.
- 아웃바운드는 IPv4 전체 허용이다. 다운로드·Tailscale 연결을 단순하게 하는 대신 외부 송신 통제는 하지 않는 초기 정책이다.

GPU 드라이버, containerd, Tailscale, kubelet, Cilium 설치 및 노드 조인, vLLM 배포는 **다음 단계**다.
기본 Ubuntu AMI만으로 GPU 워커가 완성되는 것은 아니다. SSM 접속 역시 이번 구성에 포함되지 않는다.
`bootstrap_ssh_cidr=null`이면 새 서버에 SSH 접속할 수 없다. 처음 생성할 때는 본인의 `/32`를 설정한다.
Tailscale 설치·ACL·호스트 방화벽·실제 관리 접속을 확인한 뒤 null로 되돌려 공개 SSH만 제거한다.
Tailscale 앱 접근 통제는 SG가 아닌 tailnet 정책·호스트/CNI 정책도 필요하다.

확정 사양, 단계별 중단 조건, `kubeadm join`과 원복 경계는
vLLM 노드 사양·Join 계획(Git 이력)에 있다. 이 Terraform은 호스트까지만
만들며 Join token·Tailscale auth key·모델 토큰을 `user_data`나 state에 넣지 않는다.
GPU smoke 뒤의 Prometheus Target, DCGM, vLLM, Gateway 지표와 합성 부하·장애 실험의
순서는 vLLM 관측·실험 계획(Git 이력)에 있다. 문서가 있어도
AWS 생성·Kubernetes Join·관측 리소스 Sync가 실행된 것은 아니다.

## 생성 전에 반드시 확인

1. 현재 AWS 신원·서울 리전을 직접 확인하고 `expected_account_id`를 설정한다. 자격증명은 외부 AWS profile/SSO로 제공한다.
2. 서울 `Running On-Demand G and VT instances` 적용값 4 이상 및 여유 4 vCPU 확인. 현재 상태를 실제 계정에서 먼저 읽고, 부족하면 별도 승인으로 증설을 신청한다.
3. 선택 AZ의 g6.xlarge offering 확인. 할당량·offering 확인은 실제 GPU 재고나 재시작 성공 보장이 아니다.
4. Canonical Ubuntu 24.04 amd64 일반 서버 AMI ID를 확인해 고정한다. data source는 ID·Canonical 소유자·이미지 이름·아키텍처·상태를 함께 검사한다. 자동 latest 선택은 하지 않는다.
5. AWS VPC CIDR을 홈 LAN·Pod CIDR·Service CIDR·기존 VPN/VPC 경로와 비교한다. 예시 `10.80.0.0/16`은 확정값이 아니다. 코드의 RFC1918 검사는 실제 경로 중복을 판별하지 않는다.
6. 초기 접속용 공개 키와 관리자 공인 `/32`를 준비한다. 예시 IP·키로 접속할 수 없다.
7. EC2·EBS·EIP·전송 비용을 공식 콘솔에서 재확인하고 월 10~20만원 예산 안에서 실험 시간을 정한다. EIP는 stopped 상태에도 과금되므로, 중지 기간에도 유지할 이유를 확인한다.
8. 이 검토와 생성 허가 후에만 `launch_review_confirmed=true`로 실제 plan을 실행한다. 이는 **수동 확인 표시**이며 할당량·가격 자동 검사가 아니다.

### plan 전에 실제 값이 필요한 입력

아래 일곱 개가 모두 실제 값으로 채워지기 전에는 `terraform plan`을 실행하지 않는다.
코드의 validation은 **형식**만 본다 — 형식을 통과한 값이 올바른 대상이라는 뜻은 아니다.

| 변수 | 형식 검사 | 형식으로는 알 수 없는 것 |
| --- | --- | --- |
| `expected_account_id` | 12자리 숫자 | 그 계정이 의도한 실험 계정인지 |
| `ami_id` | `ami-` + 17자 hex (8자 구형 ID는 거부) | 서울 리전의 Canonical Ubuntu 24.04 amd64인지 — data source가 소유자·이름·아키텍처로 교차 확인한다 |
| `availability_zone` | `ap-northeast-2[a-z]` | 그 AZ에 g6.xlarge offering과 **실제 재고**가 있는지 |
| `vpc_cidr` | RFC1918 `/16` | 홈 LAN·Pod CIDR(실측 `10.244.0.0/16`)·Service CIDR·기존 VPN 경로와 겹치지 않는지 |
| `ssh_public_key` | 한 줄 OpenSSH 공개 키 | 그 키의 개인 키를 실제로 갖고 있는지 |
| `bootstrap_ssh_cidr` | `/32` 또는 `null` | 그 주소가 지금 접속할 관리자 주소인지(유동 IP면 바뀐다) |
| `tailscale_peer_cidrs` | 각 항목이 `/32` | 그 peer가 direct 연결에 실제로 필요한지 — **빈 목록 유지가 기본**이다 |

`launch_review_confirmed`는 값이 아니라 위 일곱 개와 8항목 검토를 사람이 끝냈다는 표시다.

## 로컬 검증 — 계정 접근/과금 없음

이 디렉터리에서:

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test
```

`terraform test`는 AWS mock provider와 `command=plan`만 사용한다. 실제 계정에 접속하거나 리소스를 만들지 않는다.
실제 `terraform plan`은 AWS 계정 조회를 하므로 위 모의 테스트와 구분한다.
`terraform.tfvars.example`을 참고해 로컬 입력을 작성하되 예시는 그대로 배포하지 않는다.
실제 AMI/AZ/계정/경로와 SSH 접속은 mock 테스트로 검증되지 않는다.

2026-09-19 검증: Terraform 1.14.5 / AWS provider 6.63.0, fmt·validate 통과, mock plan 6건 통과.
로컬 샌드박스의 provider 프로세스 통신 제한으로 첫 validate/test가 실패했고, 제한 밖에서 동일한 비변경 검사를 재실행해 통과했다.
실제 AWS plan/apply·할당량 API 조회·접속·부팅·GPU 테스트는 실행하지 않았다.

## 상태·버전·비용 안전

- `.terraform.lock.hcl`은 provider 버전·체크섬 재현을 위해 Git 추적 대상으로 둔다. `init -upgrade`는 검토된 업그레이드에서만 사용한다.
- state, 실제 tfvars, 저장한 plan은 Git에서 제외한다. local state는 민감한 운영 파일이며 접근을 제한한다. 원격 state 저장소는 이번 범위에 추가하지 않는다.
- 실제 apply는 별도 승인 후 검토한 saved plan으로만 수행한다. 이 README나 로컬 검사 통과는 실행 허가가 아니다.
- `launch_review_confirmed=false`는 종료 스위치가 아니다. false로 되돌려도 EC2는 계속 실행된다.
- `prevent_destroy=true`는 Terraform의 EC2 삭제·교체를 차단한다. 요금 차단이나 콘솔/CLI 삭제 방지가 아니며, 리소스 선언을 제거해도 보호가 유지되는 것은 아니다.
- 일상 종료는 **EC2 Stop**이다. Pod 삭제·kubelet 중지·Terraform 코드 삭제로는 컴퓨팅 과금이 멈추지 않는다. AWS 상태가 `stopped`인지 확인한다. 이 코드에는 자동 종료 타이머·하드 예산 제한이 없다.
- EBS와 EIP는 중지 중에도 과금된다. EIP는 관리 편의를 위한 고정 SSH 목적지일 뿐이며, Kubernetes 식별값·vLLM endpoint에 쓰지 않는다. SSH 허용 범위는 계속 관리자 공인 `/32`다.
- `delete_on_termination=true`: 실제 EC2 종료(terminate) 시 루트 디스크와 모델 캐시도 삭제된다. Terraform 보호를 해제하거나 콘솔에서 종료하기 전 정확한 대상·데이터 폐기 승인이 필요하다. 이 노드에는 유일한 원본·DB를 두지 않는다.
- AMI·네트워크·키 변경은 재생성을 유발할 수 있다. plan에서 replacement가 보이면 멈추고 검토한다. `prevent_destroy=true`는 삭제뿐 아니라 **교체도 막으므로**, AMI를 바꾸면 plan이 재생성을 시도하다 하드 실패한다. 그때 보호를 임시로 끄는 것이 아니라 교체가 정말 필요한지부터 검토한다.
- 루트 볼륨 암호화는 **AWS 관리 키**다(`kms_key_id` 미지정). 고객 관리 키(CMK)의 회전·접근 감사·삭제 통제가 필요해지면 별도 결정으로 추가한다. "암호화됨"과 "키를 우리가 통제함"은 다르다.
- VPC flow log를 만들지 않는다. 네트워크 문제는 호스트·Cilium·Hubble 쪽 관측으로 본다. 송신 트래픽의 사후 감사 기록은 없다.

## 다음 단계의 네트워크 게이트

Tailscale UDP 인바운드를 열지 않아도 연결될 수 있지만 direct는 보장되지 않는다. 먼저 빈 `tailscale_peer_cidrs`로 direct/DERP를 실측한다. 고정 peer `/32`가 실제로 필요할 때만 추가하며, 가정용 유동 IP 규칙은 바뀌면 함께 갱신해야 한다.
현재 홈 Node InternalIP는 LAN 주소로 보고됐으므로 **Tailscale 설치만으로 AWS→홈 Pod 경로가 완성됐다고 보지 않는다**.
API 주소·인증서 SAN·노드/터널 주소·반환 경로·MTU를 확인한 뒤 조인한다. 홈 노드 재조인·IP 변경은 별도 계획/승인 대상이다.

서빙 기준 모델은 `Qwen/Qwen3-4B-Instruct-2507`, BF16, 입력+출력 최대 4096 토큰, 단일 GPU/vLLM이다.
8192는 이 기준선이 통과한 뒤 별도로 비교한다. 둘을 한 실행의 자동 가변 상한으로 섞지 않는다.
첫 실행 후보는 vLLM `v0.29.0-cu129-ubuntu2404`(linux/amd64 digest `sha256:51b10427…51b8`)·
CUDA 12.9.1·NVIDIA driver **R580**(Ubuntu `nvidia-driver-580-server`, 정확한 patch 고정)·Container
Toolkit 1.20.x다. R580 근거와 폐기된 선택(R570)은 Join 계획(Git 이력) §4에 있다.
모델 commit과 vLLM 이미지 digest, driver/toolkit patch는 실제 배포 전에 다시 확인한다. 한국어 품질·처리량·VRAM은 미측정이다.

## 준비 상태표 (2026-09-27)

세 구간으로 나눈다. **"준비 완료"·"배포 전 선언 초안"은 선언이나 문서가 있다는 뜻이고 동작
확인이 아니다.** 특히 "배포 전 선언 초안"은 렌더되지 않거나 미결값이 남은 상태이므로
기능이 있다고 읽지 않는다.

### 현재 클러스터·계정에 적용된 것 (2026-09-27 실측)

| 항목 | 현재 상태 | 다음 조치 |
| --- | --- | --- |
| AWS GPU EC2 | **완료** — `g6.xlarge` 생성, SSH 도달 | — |
| GPU 노드 Kubernetes 조인 | **완료** — `persona-gpu-01` 조인, `Ready` | — |
| Tailscale + Cilium Pod 간 통신 | **완료** — 구성, Pod 간 통신 확인. subnet router(`k8s-cp`)는 **현재 SNAT을 켠 상태**다 | SNAT 상태를 바꾸면 행렬을 다시 확인 |
| NVIDIA RuntimeClass·device plugin | **완료** — `RuntimeClass/nvidia`, device plugin, Node `allocatable`에 `nvidia.com/gpu: 1` | — |
| CUDA·vLLM image GPU smoke | **완료** — CUDA smoke와 vLLM image(`sha256:51b10427…51b8`) GPU smoke 성공 | — |
| GPU 관측 | **완료** — DCGM exporter·node-exporter Prometheus Target `UP`. vLLM Target `UP`(운영자 제공, 2026-09-27) | NetworkPolicy 적용 뒤 vLLM Target `UP` 유지 확인 |
| local-path GPU 노드 | **완료** — `persona-gpu-01` nodePathMap 반영, GPU 노드 고정 PVC `Bound`, 쓰기/읽기, Retain 정리 확인 | — |
| 40Gi 모델 cache PVC·seed Job | **완료(운영자 보고, 2026-09-27)** — 첫 seed 완료. 완료 marker·manifest 관측 기록은 이 문서에 없다 | PVC·Job을 바꾸거나 다시 실행하지 않는다 |
| 다운로드 FQDN 관측·Cilium FQDN allowlist | **미완료 — 이번 범위 밖** | inference 정책(특히 `allow-model-seed-dns`) 적용 뒤 seed를 다시 실행해야 할 때 먼저 만든다 |
| `persona-inference` NetworkPolicy 적용 | **미완료** — 첫 적용 가능한 선언 완성(2026-09-27). Argo Application 없음, 사람이 `kubectl apply` | allow 먼저, default-deny 마지막으로 적용 뒤 실측 a–d |
| vLLM Deployment | **완료(운영자 제공, 2026-09-27)** — non-root·read-only 기동, 비스트리밍 추론, control-plane → Service 경유 SSE `[DONE]`, Prometheus Target `UP` | 성능·과부하 실험은 미확인 |

### 준비 완료·초안 — 선언이나 문서가 있는 것 (동작 확인 아님)

| 항목 | 현재 상태 | 다음 조치 |
| --- | --- | --- |
| Terraform 선언 | **확정(2026-09-19)**, 안전 단정 보강 **완료(2026-09-25)** — mock plan 6건 통과(단정 5 → 9개) | 실제 `plan`은 입력 7개 확정 후 |
| driver/toolkit/vLLM 조합 | image digest·CUDA 12.9.1은 manifest로 확인(2026-09-25). driver는 **R580으로 확정(2026-09-27)**, R570은 폐기. R580에서 vLLM image GPU smoke 성공(2026-09-27) | driver·toolkit patch를 바꾸면 조합 smoke를 다시 실행 |
| GPU 노출 방식 | **확정(2026-09-25)·적용 완료** — NVIDIA device plugin(노드 1대 전제), `nvidia.com/gpu: 1` 확인 | — |
| Ansible playbook 5계층 | **준비 완료(2026-09-25)** — 작성했으나 **한 번도 실행하지 않았다.** `ansible` 미설치로 syntax-check·lint 미실행 | ansible 설치 환경에서 `--syntax-check`·`ansible-lint` 먼저 통과 |
| tailnet subnet router | `k8s-cp`. 2026-09-19 결정은 SNAT off였지만 **현재 운영 상태는 SNAT on**이다. 검증 행렬 7행 | SNAT 설정을 바꿀 때 행렬을 다시 실행 |
| `persona-inference` NetworkPolicy·API → vLLM ingress | **선언 있음(2026-09-27 작성)** — API(`mafest-app`의 `mafest-api`)에서 vLLM Pod TCP 8000만 허용하고, metrics는 `monitoring` ns AND Prometheus Pod만 허용한다. 적용 묶음 구분용 `apply-phase` label. validator·음성 테스트 통과 | inference는 수동 apply(Argo Application 추가 안 함), API egress는 `mafest-app-netpol` Argo Sync |
| model cache PVC·seed Job | **첫 seed 완료(운영자 보고, 2026-09-27)** — `kustomize/overlays/prod/persona-model-cache`(Namespace·40Gi PVC·seed Job). vLLM image로 `snapshot_download` 후 upstream metadata(파일 목록·크기·sha256·git blob sha1) 대조. **Argo Application 없음** | 바꾸거나 다시 실행하지 않는다 |
| model 다운로드 FQDN 정책 | **열림 — 이번 범위 밖** — 실제 호스트 관측 기록이 없고 placeholder가 들어 있어 배선하지 않았다 | seed 재실행이 필요할 때 호스트 관측 후 allowlist 확정(`allow-model-seed-dns`만 적용돼도 이것 없이 seed가 외부에 닿지 못한다) |
| 0002·0003 복원 재검증 절차 | **준비 완료(2026-09-25)** — `runbooks/material-chunks-restore-verify.md`. 실행하지 않았다 | 사용자가 CP에서 dump·격리 복원 1회 실행 |

### GPU 실행 순서와 상태 (2026-09-27)

| 순서 | 항목 | 성공 판정 | 상태 |
| --- | --- | --- | --- |
| 1 | EC2 apply와 SSH 도달 | 호스트 로그인. **이것은 tailnet·Pod 경로 성공이 아니다** | 완료 |
| 2 | Ansible `00`→`10`→`20` | swap 0, sysctl 실효값 1, containerd socket, Tailscale binary | 이 문서에 실행 결과 미기록 |
| 3 | 사람이 `tailscale up` + route 승인 | tailnet 도달성만. Pod 통신과 무관 | 완료(subnet router SNAT on) |
| 4 | Ansible `30-gpu-runtime` | `nvidia-smi`로 GPU 정확히 1장 + R580 기준선(요청 patch·DKMS) 판정 healthy | 이 문서에 실행 결과 미기록 |
| 5 | Ansible `40-join-preflight` | 버전 대조 통과. **Join 성공이 아니다** | 이 문서에 실행 결과 미기록 |
| 6 | §3 네트워크 행렬 | 행마다 증명 계층을 구분해 기록. Pod↔Pod와 DNS까지 | 완료(Tailscale+Cilium Pod 간 통신) |
| 7 | 사람이 `kubeadm join` | Node `Ready`, taint 등록 확인 | 완료 |
| 8 | RuntimeClass·device plugin 배포 | Node `allocatable`에 `nvidia.com/gpu: 1` | 완료 |
| 9 | CUDA·vLLM image GPU smoke | container 안에서 GPU 접근 | 완료 |
| 10 | DCGM exporter·node-exporter | Prometheus Target `UP` | 완료 |
| 11 | local-path nodePathMap 반영 | GPU 노드에 고정한 PVC `Bound`, 쓰기/읽기, Retain 정리 | 완료 |
| 12 | 40Gi 모델 cache PVC·seed Job 1회(inference NetworkPolicy보다 먼저) | Job `Complete` + 완료 marker·manifest, 다운로드 호스트 관측 기록. 실패면 vLLM 시작하지 않음 | 완료(운영자 보고, 기록 미첨부) |
| 13 | `persona-inference` 정책 수동 적용(적용 전 목록 보관 → allow 4개 → 확인 → default-deny → 재확인). FQDN allowlist는 범위 밖 | 단계마다 실측 a–d: Gateway→vLLM 허용, Prometheus Target `UP`, 일반 Pod→vLLM 차단, 추론 정상. 실패하면 default-deny로 진행하지 않음 | 미완료 |
| 15 | vLLM Deployment 적용 | ClusterIP 내부에서 `/health`와 최소 생성 요청 | 완료(운영자 제공: 비스트리밍 추론, Service 경유 SSE `[DONE]`) |

## 근거

- [AWS Internet Gateway와 public IPv4](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)
- [EC2 할당량](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html)
- [Canonical AMI 확인](https://documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/)
- [Tailscale 방화벽 포트](https://tailscale.com/docs/reference/faq/firewall-ports)
- [EC2 stop/terminate 수명주기](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html)
- [Qwen 공식 모델](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)
- [AWS G6 사양](https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html)
- [Kubernetes kubeadm join](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/)
- [Cilium VXLAN 경로 요구사항](https://docs.cilium.io/en/stable/network/concepts/routing/)
- [vLLM 공식 릴리스](https://github.com/vllm-project/vllm/releases/tag/v0.29.0)
- [CUDA 12.9 driver 요구사항](https://docs.nvidia.com/cuda/archive/12.9.1/cuda-toolkit-release-notes/)
