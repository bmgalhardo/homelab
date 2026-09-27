# AI / MLOps POC — GPU on elysium

**Goal:** a small but complete GPU-in-Kubernetes platform: a GPU node, a
served model behind a gateway, a benchmark that produces real latency /
throughput numbers, and all of it observable on athena and deployed by Flux.
Portfolio-shaped for MLOps roles (target on 2026-09-26: NVIDIA *Senior MLOps
Engineer — DSX Enablement*, JR2024830, Germany/remote — k8s, batch
schedulers, observability, GitOps, CI/CD, LLM performance evaluation, the
NVIDIA stack).

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
| GPU Operator: DCGM exporter, GFD | ⚠️ unverified | 750 Ti is not on the supported list. Fallback: `nvidia_gpu_exporter` (NVML / nvidia-smi) |

**Models that fit fully in VRAM** (Q4): `qwen2.5:1.5b`, `qwen3:1.7b`,
`llama3.2:1b`, `gemma3:1b`. 3B only partially offloads.

## Current state (2026-09-26)

- `elysium-hades-gpu` (vmid 1103) defined — Terraform, Omni machine class +
  Workers block (extensions + `KernelModuleConfig` patch), `elysium-nvidia`
  media preset documented. **Not applied**: needs the ISO, `terraform apply`,
  `omnictl cluster template sync` (Omni SA is Reader). Runbook:
  `infra/elysium/README.md` → GPU node.
- GPU Operator HelmRelease in `kubernetes/10-infra-base/gpu-operator.yaml`.
- `ai` namespace: `ollama` (CPU, hades, `llama3.2:1b` + `nomic-embed-text`),
  `litellm` (gateway), `openwebui`. Added `ollama-gpu` (GPU node,
  `qwen2.5:1.5b`) and LiteLLM model `qwen-gpu` with fallback to `llama-mini`.
- Talos VM CPU type `x86-64-v2-AES` → `x86-64-v3` (AVX2; both hosts
  verified). v2 hid AVX from the guests, crippling CPU inference and
  blocking vLLM's CPU backend. Needs a VM restart per node to apply.

## Power model

The GPU VM is off by default and swapped by hand with VM 102 (Hades has RAM
for one of them). So: **anything that must answer at any time stays on the
CPU `ollama`**. `ollama-gpu` is Pending while the GPU node is off; LiteLLM
falls back to `llama-mini`. The fallback is a feature of the POC, not a
workaround — it is the "graceful degradation" story.

## Build order

1. **GPU node up** — ISO → apply → sync → swap GPU in. Exit:
   `nvidia-operator-validator` Completed, node advertises `nvidia.com/gpu: 1`.
2. **Serve** — `ollama-gpu` Running, `qwen-gpu` answers via LiteLLM, fallback
   verified by stopping the GPU VM mid-session.
3. **Observe** — k8s + GPU + LiteLLM metrics on athena (plan: `argus.md` →
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

- [ ] DCGM exporter on Maxwell — works, or switch to `nvidia_gpu_exporter`
- [ ] Taint the GPU node so only GPU workloads land there (evicted on swap)
- [ ] Node sizing for step 5–6 (elysium workers are 4–8 GB)
