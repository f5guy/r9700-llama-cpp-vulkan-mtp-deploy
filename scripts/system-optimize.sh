#!/bin/bash
# AMD RDNA4 system-level optimizations for LLM inference
# Run with sudo / 需要 sudo 执行
# Reference: https://github.com/ggml-org/llama.cpp/discussions/21043
#
# Installs a systemd oneshot unit so the tuning survives reboots
# (instead of relying on rc.local, which many systemd distros ignore).

set -e

CARD="${1:-card1}"   # AMD GPU card index under /sys/class/drm — check with: ls /sys/class/drm/card*/device/uevent && grep -l amdgpu /sys/class/drm/card*/device/uevent

echo "[1/3] Setting PCIe ASPM to performance mode (+~10% decode)..."
echo performance | tee /sys/module/pcie_aspm/parameters/policy

echo "[2/3] Setting GPU power level to high (stable clocks) on $CARD..."
if [ -f "/sys/class/drm/$CARD/device/power_dpm_force_performance_level" ]; then
    echo high | tee "/sys/class/drm/$CARD/device/power_dpm_force_performance_level"
else
    echo "  WARNING: /sys/class/drm/$CARD/device/power_dpm_force_performance_level not found."
    echo "  Find the right card with: for f in /sys/class/drm/card*/device/uevent; do grep -q amdgpu \$f && echo \$f; done"
fi

echo "[3/3] Installing systemd unit for persistence across reboots..."
cat > /usr/local/sbin/amdgpu-perf-tune.sh <<EOF
#!/bin/sh
echo performance > /sys/module/pcie_aspm/parameters/policy
for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
    if grep -q amdgpu "\$(dirname "\$f")/uevent" 2>/dev/null; then
        echo high > "\$f"
    fi
done
EOF
chmod 755 /usr/local/sbin/amdgpu-perf-tune.sh

cat > /etc/systemd/system/amdgpu-perf-tune.service <<'EOF'
[Unit]
Description=AMD RDNA4 PCIe ASPM + GPU power tuning for llama.cpp inference
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/amdgpu-perf-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now amdgpu-perf-tune.service

echo ""
echo "Done. Verify with:"
echo "  cat /sys/module/pcie_aspm/parameters/policy"
echo "  cat /sys/class/drm/$CARD/device/power_dpm_force_performance_level"
echo "  systemctl status amdgpu-perf-tune.service"
