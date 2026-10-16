# CoreDNS: Tailscale 검색 도메인 조회를 바깥으로 넘기지 않기

kubeadm 이 만든 `kube-system/coredns` ConfigMap 에 `tail94eeff.ts.net` 영역 블록 하나를 더한다.
CoreDNS 는 kubeadm 이 소유하므로 Argo CD 가 관리하지 않고, 이 폴더의 매니페스트를 **사람이 적용한다**.
이 저장소 변경만으로는 클러스터가 바뀌지 않는다.

## 왜 필요한가

- 노드의 `/run/systemd/resolve/resolv.conf` 에 `search tail94eeff.ts.net` 이 있고, kubelet 이 이를 Pod 에 상속한다.
  Pod 의 `resolv.conf` 는 `search <ns>.svc.cluster.local svc.cluster.local cluster.local tail94eeff.ts.net`, `ndots:5` 다.
- 그래서 바깥 도메인을 조회할 때마다 `<이름>.tail94eeff.ts.net` 이 공용 DNS(1.1.1.1, 8.8.8.8)까지 나갔다가 NXDOMAIN 으로 돌아온다.
- 측정(2026-10-16 22:30~23:30 KST, Prometheus): 바깥으로 넘긴 조회(`coredns_proxy_request_duration_seconds_count{proxy_name="forward"}`)
  중 NXDOMAIN 약 0.16건/초, NOERROR 약 0.025건/초(약 86%가 NXDOMAIN), SERVFAIL 0. 상위 서버별 p50 은 1.1.1.1 약 3~5ms,
  8.8.8.8 약 50~60ms. 전체 응답 p99 는 0.23~0.39초(히스토그램 버킷 경계 영향이 있어 구간으로만 본다).
- 이 클러스터는 노드 간 통신에 Tailnet IP 를 직접 쓴다. Pod 가 ts.net 이름을 조회할 이유는 확인된 바 없고, 공용 DNS 는 tailnet 이름을
  원래 풀지 못한다. 그래서 차단해도 지금 성공하던 조회가 실패로 바뀌지는 않는다(확인된 바 없음이지 전수 확인은 아니다).

## 무엇을 바꾸나

`configmap.yaml` 은 2026-10-16 에 클러스터에서 받은 `Corefile`(CoreDNS `registry.k8s.io/coredns/coredns:v1.14.2`)에 아래 블록만 더했다.
기존 `.:53` 블록은 바꾸지 않았다.

```
tail94eeff.ts.net:53 {
    errors
    template ANY ANY {
        rcode NXDOMAIN
    }
}
```

## 적용 절차 (사람이 한다)

```bash
# 1. 백업. 되돌릴 때 쓴다.
kubectl -n kube-system get cm coredns -o yaml > coredns-backup.yaml

# 2. 적용 전 차이 확인(읽기 전용)
kubectl -n kube-system diff -f bootstrap/coredns/configmap.yaml

# 3. 적용. 이 ConfigMap 은 kubeadm 이 만들어 last-applied 주석이 없어 경고가 한 번 나올 수 있다.
kubectl apply -f bootstrap/coredns/configmap.yaml
```

- **재시작은 필요 없다.** 현재 Corefile 의 `.:53` 블록에 `reload` 플러그인이 있어 변경을 자동으로 읽는다(보통 수십 초 이내).
  반영됐는지는 CoreDNS Pod 로그에서 reload 메시지를 확인한다. 자동 반영되지 않으면 `kubectl -n kube-system rollout restart deploy/coredns`.
- 확인: 아래 "반영 뒤 확인"을 쓴다.

## 되돌리기

```bash
kubectl apply -f coredns-backup.yaml
```
백업에는 `resourceVersion`·`uid` 가 들어 있어 충돌하면 `metadata` 의 그 필드를 지우고 적용한다. 이 역시 `reload` 로 자동 반영된다.

## 주의

- **kubeadm 업그레이드가 `coredns` ConfigMap 을 기본값으로 덮어쓸 수 있다.** 업그레이드 뒤에는 이 블록이 남아 있는지 확인하고, 없으면 다시 적용한다.
- 이 매니페스트의 `.:53` 블록은 위 시점의 클러스터 출력이다. CoreDNS 설정이 그 뒤 바뀌었다면 적용 전에 `kubectl diff` 로 차이를 먼저 본다.

## 검사 기록

- 새 블록만 담은 Corefile 로 같은 이미지(`v1.14.2`)를 로컬 컨테이너에서 띄워 `tail94eeff.ts.net` 과 그 하위 이름이 NXDOMAIN,
  영역 밖 이름(`example.com`)은 REFUSED 로 답하는 것을 확인했다. `template` 플러그인이 이 빌드에 들어 있다.
- **전체 Corefile 은 로컬에서 끝까지 기동하지 못했다.** `kubernetes` 플러그인이 클러스터 안 환경변수(API 주소)를 요구해서 중단된다.
  새 블록 밖의 지시문은 클러스터 출력 그대로라 변경이 없다. 실제 클러스터에서의 reload 와 효과는 미검증이다.

## 반영 뒤 확인

```bash
# Pod 안에서 (CoreDNS 가 새 블록을 읽은 뒤)
kubectl run dns-check --rm -it --restart=Never --image=<DNS 도구가 있는 이미지> -- nslookup example.tail94eeff.ts.net
```
```promql
# 바깥으로 넘기는 NXDOMAIN 이 약 0.16건/초에서 거의 0으로
sum by (rcode) (rate(coredns_proxy_request_duration_seconds_count{proxy_name="forward"}[5m]))
# 전체 응답 p99 (전후 비교)
histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[5m])))
```
측정 효과는 이 변경 하나만의 결과로 해석한다. 아래 후보를 한 번에 함께 바꾸지 않는다.

## 다음 단계 (이번 범위 밖, 후보)

- 상위 서버 순서: `forward . /etc/resolv.conf { max_concurrent 1000 }` 을 `policy sequential` 로 바꿔 1.1.1.1 을 우선한다. 한 번에 하나만
  바꿔 효과를 따로 재려고 이번에는 바꾸지 않았다.
- 근본 원인 제거: 노드에서 검색 도메인을 빼는 방법(kubelet `resolvConf` 또는 `tailscale set --accept-dns=false`, `systemd-resolved`).
  노드 4대에서 kubelet 재시작이 필요해 별도 작업으로 다룬다.
- Pod 별 `dnsConfig`(`ndots` 조정)는 추가하지 않았다.
