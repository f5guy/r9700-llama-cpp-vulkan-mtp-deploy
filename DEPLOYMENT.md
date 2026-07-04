# Deployment Runbook — AMD R9700 + llama.cpp Vulkan + MTP

A step-by-step guide to go from a clean Ubuntu 24.04 server to a running
`llama-server` serving Qwen3.6-27B over the Vulkan/RADV backend with MTP
speculative decoding, packaged with Docker Compose. Validated on an AMD
Radeon AI PRO R9700 (gfx1201).

Target flags — the deployment must be able to run this:

```
--n-gpu-layers 999 --ctx-size 204800 --parallel 1 --flash-attn on \
-b 16384 -ub 2048 --cache-type-k q4_0 --cache-type-v q4_0 \
--spec-type draft-mtp --spec-draft-n-max 3
```

---

## 0. Prerequisites

- Ubuntu 24.04.x, an AMD RDNA4 GPU (R9700 / RX 9700, PCI ID `1002:7551`) attached/passed through
- Passwordless `sudo` (or be ready to type your password at each `sudo` step)
- At least ~25GB free disk for the Q4_K_M model (17GB) plus build artifacts

---

## 1. Fix the GPU driver (the step most people miss)

Ubuntu 24.04's default GA kernel (`6.8.0-*-generic`) does **not** support
RDNA4/gfx1201. Symptom:

```bash
sudo dmesg | grep -i amdgpu
# amdgpu 0000:13:00.0: amdgpu: Fatal error during GPU init
# amdgpu: probe of 0000:13:00.0 failed with error -22
```

If you see this, `vulkaninfo` will only show `llvmpipe` (software rasterizer),
never `radv`. Fix: install Canonical's official OEM kernel line (already
signed, works with Secure Boot enabled, no ROCm/DKMS needed since this whole
stack only uses the Vulkan/RADV path):

```bash
sudo apt-get update
sudo apt-get install -y linux-oem-24.04d linux-firmware
sudo reboot
```

After reboot, confirm:

```bash
uname -r                       # should print 6.17.0-xxxx-oem (or newer)
sudo dmesg | grep -i amdgpu    # should show "VRAM: 32624M ... ready", no more "Fatal error"
```

If you're on a different/older AMD GPU the stock kernel may already be
sufficient — check dmesg first either way.

---

## 2. Install build dependencies + Vulkan tooling

```bash
sudo apt-get install -y \
  build-essential libvulkan-dev vulkan-tools glslc glslang-tools \
  spirv-tools spirv-headers mesa-vulkan-drivers \
  libcurl4-openssl-dev libssl-dev pkg-config ninja-build cmake git
```

Confirm RADV sees the real GPU (not llvmpipe):

```bash
sudo usermod -aG video,render "$USER"   # requires re-login (or `sg render -c "sg video -c '...'"`) to take effect
# reconnect your SSH session, then:
vulkaninfo --summary | grep -iE "deviceName|driverName"
# deviceName = AMD Radeon Graphics (RADV GFX1201)
# driverName = radv
```

---

## 3. Build llama.cpp (Vulkan backend)

```bash
./scripts/build-vulkan-mtp.sh ~/llama-mtp-vulkan
```

This clones the latest `llama.cpp` master (`--depth 1`), configures with
`-DGGML_VULKAN=ON -DGGML_CPU=ON -DCMAKE_BUILD_TYPE=Release`, and builds the
`llama-server` target. The configure log should include:

```
-- GL_KHR_cooperative_matrix supported by glslc
-- Including Vulkan backend
```

Confirm the binary supports MTP:

```bash
~/llama-mtp-vulkan/build/bin/llama-server --help | grep spec-type
# must list "draft-mtp" among the available types
```

---

## 4. System tuning (PCIe ASPM + GPU power) — persists across reboots

```bash
sudo ./scripts/system-optimize.sh
```

This auto-detects the AMD card under `/sys/class/drm/` and sets:
- PCIe ASPM policy → `performance` (+~10% decode throughput)
- GPU power level → `high` (prevents clock throttling/instability)

...then installs a systemd oneshot unit (`amdgpu-perf-tune.service`) so both
settings are reapplied on every boot — no need to touch `rc.local`.

---

## 5. Download the model (must use the MTP-preserving repo)

**Important:** "plain" GGUF repos (without `-MTP` in the name) have the MTP
head tensors stripped out to save space — `--spec-type draft-mtp` would have
nothing to draft from. You must use the dedicated MTP repo:

```bash
mkdir -p ~/llama-mtp-vulkan/models/gguf
curl -L -o ~/llama-mtp-vulkan/models/gguf/Qwen3.6-27B-Q4_K_M.gguf \
  "https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF/resolve/main/Qwen3.6-27B-Q4_K_M.gguf"
```

(repo: `unsloth/Qwen3.6-27B-MTP-GGUF`, file `Qwen3.6-27B-Q4_K_M.gguf`, ~17.1GB)

---

## 6. Docker: build the runtime image and deploy via Compose

### 6.1 Install Docker

```bash
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # re-login to use docker without sudo
```

### 6.2 Build the image from the binaries you already compiled (fast — no in-container recompile)

```bash
./scripts/build-docker-image.sh ~/llama-mtp-vulkan/build/bin
```

Uses [`docker/Dockerfile.runtime`](docker/Dockerfile.runtime) — copies only
the required binary + shared libs, and installs `mesa-vulkan-drivers` inside
the image so the RADV ICD driver is present.

### 6.3 Adjust `docker-compose.yml` for this server

In the `llama-27b` service, edit:
- `volumes:` → point at wherever the `.gguf` file actually lives on this host
- `group_add:` → the `video`/`render` group GIDs on this host (they can differ
  between machines). Get them with:
  ```bash
  getent group video render
  ```

### 6.4 Run it

```bash
docker compose up -d llama-27b
docker compose logs -f llama-27b   # wait for "listening on http://0.0.0.0:8080"
```

---

## 7. Verify (exercise the golden path before calling it done)

```bash
curl -s http://localhost:8080/health

curl -s http://localhost:8080/v1/completions -H 'Content-Type: application/json' \
  -d '{"prompt": "The capital of France is", "max_tokens": 32, "temperature": 0}'
```

The response `timings` object should show:
- `predicted_per_second` — actual generation throughput
- `draft_n` / `draft_n_accepted` — proof MTP is active (accepted > 0)

Confirm the GPU is actually doing the work (not silently falling back to CPU):

```bash
CARD=card1   # check with `ls /sys/class/drm/` on this box — the AMD card, not vmwgfx/card0
cat /sys/class/drm/$CARD/device/mem_info_vram_used | awk '{printf "%.2f GiB\n", $1/1024/1024/1024}'
# should read ~20+ GiB once the model is loaded

watch -n1 "cat /sys/class/drm/$CARD/device/gpu_busy_percent"
# fire the curl request above while this is running — busy% should spike above 80% then drop back to idle
```

(Optional) Install `nvtop` for a live htop-style GPU dashboard:

```bash
sudo apt-get install -y nvtop
nvtop
```

---

## Summary checklist

| # | Step | Key command |
|---|------|-----------|
| 1 | Fix kernel GPU driver | `apt install linux-oem-24.04d linux-firmware && reboot` |
| 2 | Install build deps | `apt install build-essential libvulkan-dev vulkan-tools glslc ...` |
| 3 | Build llama.cpp Vulkan | `./scripts/build-vulkan-mtp.sh` |
| 4 | System tuning (persist) | `sudo ./scripts/system-optimize.sh` |
| 5 | Download MTP model | `curl -L .../unsloth/Qwen3.6-27B-MTP-GGUF/.../Qwen3.6-27B-Q4_K_M.gguf` |
| 6 | Build Docker image + deploy | `./scripts/build-docker-image.sh && docker compose up -d llama-27b` |
| 7 | Verify | `curl .../v1/completions` + check VRAM/gpu_busy_percent |

## Common issues

| Symptom | Cause | Fix |
|---|---|---|
| `vulkaninfo` only shows `llvmpipe` | Kernel doesn't support the ASIC | Step 1 |
| `Could not find ... SPIRV-Headers` during cmake configure | Missing package | `apt install spirv-headers` |
| `docker compose up` fails with `Unable to find group render` | Base image has no such group in `/etc/group` | Use numeric GIDs in `group_add` (`getent group render`) instead of names |
| MTP gives no speedup / `draft_n_accepted` = 0 | Downloaded a GGUF without MTP heads | Must download from a repo with `-MTP` in the name (step 5) |
| Port 8080 already in use when starting the container | A native `llama-server` process is still running | `pkill llama-server` before `docker compose up` |
