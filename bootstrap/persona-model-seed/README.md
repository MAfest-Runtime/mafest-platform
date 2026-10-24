# 모델별 seed와 FP8-B 운영 절차

Qwen 공식 FP8 체크포인트를 받아 운영 vLLM에 쓰기 위한 사용자 절차다. 이 저장소의 변경은 manifest까지이고,
적용·Job 실행·관측은 사용자가 한다. 모든 `kubectl`에 `--context`를 붙인다. GPU 노드가 켜져 있어야 한다
(모델 cache PVC가 GPU 노드 로컬 디스크다).

```bash
CTX=<홈 클러스터 context>
kubectl config get-contexts
kubectl --context $CTX get nodes          # 대상 클러스터와 persona-gpu-01 Ready 확인
```

## 고정값 (2026-10-21 Hugging Face API로 확인)

| 항목 | 값 |
| --- | --- |
| 모델 | `Qwen/Qwen3-4B-Instruct-2507-FP8` (공개, gated 아님) |
| revision (main) | `8591804019c8b22094c3b5b4454e0edc05dffc98` |
| 파일 | 10개, 합계 5,205,960,098 B (약 4.85 GiB). 가중치는 `model.safetensors` 5,190,053,264 B 하나 |
| 양자화 | `quantization_config`: `quant_method: fp8`, `fmt: e4m3`, `activation_scheme: dynamic`, `weight_block_size: [128, 128]`, `modules_to_not_convert` 73개(`lm_head`, 36개 층의 `input_layernorm`·`post_attention_layernorm`) |

- **weight index가 없다.** 이 체크포인트는 `model.safetensors.index.json` 없이 단일 파일이다. 그래서 `seed_model.py`는
  index가 있으면 기존대로(index와 shard 존재), 없으면 `model.safetensors`를 필수로 확인하도록 일반화했고,
  운영 vLLM의 init container도 index 대신 `model.safetensors`를 확인한다. BF16 체크포인트는 index가 있어 판정이 같다.
- **BF16 seed overlay를 다시 apply하지 않는다.** 스크립트가 바뀌어 ConfigMap 이름의 hash가 바뀌었고, 이미 끝난 BF16 Job은
  옛 ConfigMap을 가리킨다. Job은 불변이라 `kustomize/overlays/prod/persona-model-cache`를 다시 apply하면 오류가 난다.
  BF16 cache와 서빙에는 영향이 없다. BF16을 다시 검증해야 하면 Job을 지우고 적용한다.
- **PVC 용량**: 40Gi 중 BF16이 약 7.5GiB라 여유는 약 32.5GiB이고 FP8 추가 후 약 27.7GiB다. seed는 `.staging`에서 같은
  파일시스템 안에서 rename하므로 이중으로 차지하지 않는다. 실제 사용량은 아래 1)로 확인한다.

## 1) 용량 확인

```bash
kubectl --context $CTX -n persona-inference exec deploy/persona-vllm -c vllm -- df -h /models
kubectl --context $CTX -n persona-inference exec deploy/persona-vllm -c vllm -- sh -c 'du -sh /models/*'
```

## 2) 관측 정책 적용

persona-inference는 default-deny라 seed Pod가 Hugging Face에 닿지 못한다. 어느 호스트를 쓰는지 추측하지 않고 관측하려고
`allow-model-seed-observe`를 **관측하는 동안만** 올린다(어떤 kustomization에도 들어 있지 않다).

```bash
kubectl --context $CTX apply -f kustomize/base/networkpolicy/persona-inference/allow-model-seed-observe.yaml
kubectl --context $CTX -n persona-inference get ciliumnetworkpolicy allow-model-seed-observe
```

이 정책은 DNS 질의 전체(`matchPattern "*"`)를 허용해 Cilium DNS 프록시가 모든 질의 이름을 보게 하고, HTTPS는
`huggingface.co` 하나만 연다.

## 3) 관측 준비 (GPU 노드 cilium-agent)

Cilium 1.20.1 agent 이미지에는 Hubble CLI가 들어 있고 `HUBBLE_SERVER`가 agent의 unix socket으로 설정돼 있다
(이미지에서 `hubble version`과 `observe --help`로 확인했다).

```bash
AGENT=$(kubectl --context $CTX -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=persona-gpu-01 -o jsonpath='{.items[0].metadata.name}')
echo $AGENT

# 별도 터미널에서 계속 켜 둔다: seed Pod의 DNS 질의와 막힌 흐름
kubectl --context $CTX -n kube-system exec $AGENT -c cilium-agent -- \
  hubble observe --namespace persona-inference --protocol dns -f
kubectl --context $CTX -n kube-system exec $AGENT -c cilium-agent -- \
  hubble observe --namespace persona-inference --pod persona-vllm-model-seed --verdict DROPPED -f
```

보조: agent가 기억하는 FQDN → IP 캐시. 여기에 이름이 있으면 그 이름이 질의된 것이다.

```bash
kubectl --context $CTX -n kube-system exec $AGENT -c cilium-agent -- cilium-dbg fqdn cache list
kubectl --context $CTX -n kube-system exec $AGENT -c cilium-agent -- cilium-dbg fqdn cache list -s lookup
```

## 4) FP8 seed 적용과 호스트 반복 기록

```bash
kubectl --context $CTX apply -k kustomize/overlays/prod/persona-model-seed-qwen3-4b-fp8
kubectl --context $CTX -n persona-inference logs -f job/persona-vllm-model-seed-qwen3-4b-fp8
kubectl --context $CTX -n persona-inference get job persona-vllm-model-seed-qwen3-4b-fp8
```

Job은 불변이고 `backoffLimit: 0`이라 실패하면 그대로 멈춘다. 실패하면:

1. 3)의 DNS 출력에서 이 회차에 **새로 질의된** 호스트 이름을 모두 기록한다(끝의 `.`은 뺀다).
2. 관측 정책 파일의 `toFQDNs`에 `matchName`으로 그 이름만 더한다. **와일드카드(`matchPattern`)는 HTTPS 대상에 쓰지 않는다.**
   `kubectl --context $CTX apply -f …allow-model-seed-observe.yaml`로 다시 올린다.
3. Job을 지우고 다시 적용한다.
   `kubectl --context $CTX -n persona-inference delete job persona-vllm-model-seed-qwen3-4b-fp8`
4. 성공할 때까지 반복하고 회차마다 호스트 목록을 기록한다.

| 회차 | 새로 질의된 호스트 | 정책에 더한 matchName | Job 결과 |
| --- | --- | --- | --- |
| 1 | (기록) | huggingface.co만 | (기록) |

## 5) 성공 확인

```bash
kubectl --context $CTX -n persona-inference logs job/persona-vllm-model-seed-qwen3-4b-fp8 | tail -20     # 검증 결과
REV=8591804019c8b22094c3b5b4454e0edc05dffc98
kubectl --context $CTX -n persona-inference exec deploy/persona-vllm -c vllm -- \
  cat /models/Qwen/Qwen3-4B-Instruct-2507-FP8/$REV/.persona-seed-complete.json
kubectl --context $CTX -n persona-inference exec deploy/persona-vllm -c vllm -- df -h /models
```

## 6) 관측 정책 삭제와 인계

```bash
kubectl --context $CTX -n persona-inference delete ciliumnetworkpolicy allow-model-seed-observe
```

4)에서 기록한 호스트 목록은 `kustomize/base/networkpolicy/persona-inference/network-policy-fqdn.yaml`의 `matchName`에 들어간다
(상시 정책, `persona-inference-netpol` overlay로 적용). CDN 호스트 이름이 바뀌어 seed가 막히면 이 절차로 다시 관측한다.

## 7) FP8-B 운영 전환과 확인

운영 vLLM(`kustomize/overlays/prod/persona-vllm`)은 FP8-B(이 체크포인트) + CPU n-gram 추측 디코딩이다.
seed가 끝나 marker가 있어야 init container가 통과한다.

```bash
kubectl --context $CTX diff -k kustomize/overlays/prod/persona-vllm
kubectl --context $CTX apply -k kustomize/overlays/prod/persona-vllm
kubectl --context $CTX -n persona-inference rollout status deploy/persona-vllm
KUBE_CONTEXT=$CTX bash vllm-baseline-inspect.sh      # persona-ops-lab experiments/LLM-02-baseline
```

- diff는 모델 경로, init container의 `dir=`·`revision` 검사·필수 파일, `--speculative-config` 두 줄만 바뀌어야 한다.
- 기동 로그에서 커널·추측 디코딩·KV cache를 확인한다. 예상: `MarlinFP8ScaledMMLinearKernel`(L4에서는 가중치만 FP8),
  async scheduling 비활성 경고, `method='ngram'`, KV cache 약 98,800토큰.

```bash
kubectl --context $CTX -n persona-inference logs deploy/persona-vllm -c vllm | grep -i -E "Selected .* for |async|specul|KV cache size"
```

- 품질 평가·탐침·재전송은 ops-lab `experiments/LLM-02-baseline/README.md` 절차를 따른다.
- 실험 overlay: `kustomize/overlays/exp/persona-vllm-bf16`(BF16 비교·되돌리기).

## 8) 되돌리기

```bash
kubectl --context $CTX apply -k kustomize/overlays/exp/persona-vllm-bf16
kubectl --context $CTX -n persona-inference rollout status deploy/persona-vllm
```

BF16 cache는 PVC에 그대로 있다. BF16으로 되돌려도 FP8 체크포인트는 PVC에 남아 서빙에 영향이 없다.
