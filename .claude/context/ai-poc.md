# AI / MLOps POC — GPU on elysium

**Goal:** a small but complete GPU-in-Kubernetes platform: a GPU node, a
served model behind a gateway, a benchmark that produces real latency /
throughput numbers, and all of it observable on athena and deployed by Flux.
A learning project for MLOps practice: k8s, batch schedulers, observability,
GitOps, CI/CD, LLM performance evaluation, the NVIDIA stack.

Model size is not the point. Wiring, measurement and operability are.

## Hardware reality — GTX 750 Ti

2 GB VRAM, **compute capability 5.0** (Maxwell, GM107), on Hades, shared with
VM 102 `personal` via the `nvidia_750ti` PCI mapping.

| Stack | Works | Why |
|-------|-------|-----|
| Talos driver | ✅ | `nonfree-kmod-nvidia-lts` 580 only — open modules need Turing+, `-production` (595) dropped Maxwell |
| Ollama / llama.cpp | ✅ | Ollama supports CC ≥ 5.0; CC 5.0–6.2 needs driver ≥ 570 |
| vLLM (GPU) | ❌ | Requires CC ≥ 7.0 |
| TensorRT-LLM, NIM, Triton+TensorRT, NeMo | ❌ | Need newer GPUs — rent a cloud T4/L4 by the hour for these |
| GPU Operator: device plugin, NFD, validator | ✅ expected | Driver/toolkit off (Talos extensions provide them) |
| GPU Operator: DCGM exporter, GFD | ✅ verified | Not on the supported list, but both work (DCGM power reading unreliable) |

**Models that fit fully in VRAM** (Q4): `qwen2.5:1.5b`, `qwen3:1.7b`,
`llama3.2:1b`, `gemma3:1b`. 3B only partially offloads.

## Current state (2026-09-27)

- **GPU node live** — `talos-pcf-vwh` (vmid 1103), driver 580.178.04 loaded,
  GPU Operator validator passed, node advertises `nvidia.com/gpu: 1`. DCGM
  metrics reach athena with real values (2026-09-28).
- **Serving works** — `llama-mini` (CPU) and `qwen-gpu` answer via LiteLLM →
  Open WebUI. Needed `ollama_chat/` (not `ollama/`): `/api/generate` flattens
  the chat into one prompt and the 1B model answered Open WebUI's task
  prompts with JSON schemas.
- **Partial offload** — `qwen2.5:1.5b` gets 21/29 layers on GPU (716 MiB);
  Ollama's fit estimate with the 4096 default ctx holds 8 layers on CPU
  despite 1959 MiB free. Ollama's CUDA 13 runner skips CC 5.0; the CUDA 12
  runner serves it. Latency: ~6.6 s warm on GPU vs 15–60 s on CPU. Tuning
  target for step 4.
- **Context vs VRAM** — `OLLAMA_CONTEXT_LENGTH=2048` only reached 24/29
  layers and truncated Open WebUI's ~5k-token prompts to 1026 (`truncating
  input prompt`) → the model answered a fragment with a stock refusal. On 2 GB,
  1.5B + real chat context + full offload is pick-two. Now 8192: correct
  answers, fewer GPU layers; measure the cost in step 4.
- **VRAM, measured at 8192 ctx** (DCGM `FB_USED` = 1027 MiB): weights 659
  (19/29 layers) + KV 144 (+80 on CPU = 224 = 28 KB/token × 8192) + compute
  119 + CUDA/driver ≈ 105. ~900 MiB unused → Ollama's fit estimate is very
  conservative; try `num_gpu 99` in step 4. Offload vs ctx: 2048→24,
  4096→21, 8192→19 layers. 5.2k-token prompt: 1m12s, mostly prefill.
- **Fallback verified** — GPU VM stopped, `ollama-gpu` Pending, a `qwen-gpu`
  request was served by the CPU `ollama` (`llama3.2:1b`, 1m11s cold). Open WebUI
  still labels it `qwen-gpu`; the backend shows in LiteLLM's
  `x-litellm-model-api-base` / `x-litellm-attempted-fallbacks` headers.

### Earlier (2026-09-26)

- `elysium-hades-gpu` (vmid 1103) defined — Terraform, Omni machine class +
  Workers block (extensions + `KernelModuleConfig` patch), `elysium-nvidia`
  media preset in `infra/elysium/omni/media-presets.yaml`. Applied
  2026-09-27 (no virtiofs on this node). Runbook: `infra/elysium/README.md`
  → GPU node.
- GPU Operator HelmRelease in `kubernetes/10-infra-base/gpu-operator.yaml`.
- `ai` namespace: `ollama` (CPU, hades, `llama3.2:1b` + `nomic-embed-text`),
  `litellm` (gateway), `openwebui`. Added `ollama-gpu` (GPU node,
  `qwen2.5:1.5b`) and LiteLLM model `qwen-gpu` with fallback to `llama-mini`.
- Talos VM CPU type `x86-64-v2-AES` → `x86-64-v3` (AVX2; both hosts
  verified). v2 hid AVX from the guests, crippling CPU inference and
  blocking vLLM's CPU backend. Applied 2026-09-27 on all Talos VMs.

## Power model

The GPU VM is off by default and swapped by hand with VM 102 (Hades has RAM
for one of them). So: **anything that must answer at any time stays on the
CPU `ollama`**. `ollama-gpu` is Pending while the GPU node is off; LiteLLM
falls back to `llama-mini`. The fallback is a feature of the POC, not a
workaround — it demonstrates graceful degradation.

## Build order

1. ✅ **GPU node up** — ISO → apply → sync → swap GPU in. Exit:
   `nvidia-operator-validator` Completed, node advertises `nvidia.com/gpu: 1`.
2. ✅ **Serve** — `ollama-gpu` Running, `qwen-gpu` answers via LiteLLM, fallback
   verified by stopping the GPU VM mid-session.
3. ✅ **Observe** (2026-09-28) — k8s + GPU + LiteLLM metrics on athena (plan: `argus.md` →
   Phase 2a). Grafana dashboard: GPU util/mem/temp/power, tokens/s, TTFT,
   request rate, fallbacks.
4. **Benchmark** — GenAI-Perf / AIPerf as a k8s Job against the LiteLLM
   endpoint (client-side, CPU — the old card doesn't matter). TTFT, ITL,
   tokens/s over a concurrency sweep; GPU vs CPU backend. Results pushed to
   Prometheus and kept as artifacts. Pair with `lm-evaluation-harness` for
   accuracy.
5. **Pipeline** — Kueue for GPU job queueing; Argo Workflows for
   benchmark → evaluate → register (MLflow) → promote (GitOps PR). Everything
   via Flux.
6. **vLLM without a GPU** — vLLM CPU backend, 0.5B model, to practise its
   deployment + metrics. Needs step-0 AVX2 and a node with RAM to spare.
7. **NVIDIA stack** — same manifests pointed at a rented GPU for NIM /
   Triton / TensorRT-LLM.

## Open

- [x] DCGM exporter on Maxwell — works (14 metrics: util, FB used/free, temp,
      clocks). `POWER_USAGE` reads ~0.75 W idle — treat as unreliable on this card
- [ ] Taint the GPU node so only GPU workloads land there (evicted on swap)
- [ ] Node sizing for step 5–6 (elysium workers are 4–8 GB)
