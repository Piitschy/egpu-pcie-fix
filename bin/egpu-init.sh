#!/bin/sh
# Force NVIDIA eGPU PCIe target speed before binding NVIDIA.
# No device remove. No retrain if a driver is already bound.

set -eu

GPU_WAIT_TOTAL="90"
GPU_WAIT_STEP="3"
TB_ROOT="0000:00:07.3"
TARGET_GEN="3"

log() { printf '%s\n' "$*" >&2; }

find_gpu() {
  for dev in /sys/bus/pci/devices/*; do
    [ -r "$dev/vendor" ] || continue
    [ -r "$dev/class" ] || continue
    vendor=$(cat "$dev/vendor" 2>/dev/null || true)
    class=$(cat "$dev/class" 2>/dev/null || true)
    case "$vendor:$class" in
      0x10de:0x030000|0x10de:0x030200) basename "$dev"; return 0 ;;
    esac
  done
  return 1
}

link_speed() {
  cat "/sys/bus/pci/devices/$1/current_link_speed" 2>/dev/null || echo "unknown"
}

keep_awake() {
  bdf="$1"
  [ -e "/sys/bus/pci/devices/$bdf/power/control" ] && echo on > "/sys/bus/pci/devices/$bdf/power/control" 2>/dev/null || true
  [ -e "/sys/bus/pci/devices/$bdf/d3cold_allowed" ] && echo 0 > "/sys/bus/pci/devices/$bdf/d3cold_allowed" 2>/dev/null || true
}

bar0_valid() {
  first=$(sed -n '1p' "/sys/bus/pci/devices/$1/resource" 2>/dev/null || true)
  start=$(printf '%s\n' "$first" | awk '{print $1}')
  end=$(printf '%s\n' "$first" | awk '{print $2}')
  [ -n "$start" ] && [ -n "$end" ] && [ "$start" != "0x0000000000000000" ] && [ "$end" != "0x0000000000000000" ]
}

wait_for_gpu() {
  waited=0
  while [ "$waited" -lt "$GPU_WAIT_TOTAL" ]; do
    bdf=$(find_gpu || true)
    if [ -n "$bdf" ]; then
      printf '%s\n' "$bdf"
      return 0
    fi

    case "$waited" in
      6|18|36)
        if [ -e "/sys/bus/pci/devices/$TB_ROOT/rescan" ]; then
          log "Rescan TB root $TB_ROOT while GPU is absent"
          echo 1 > "/sys/bus/pci/devices/$TB_ROOT/rescan" 2>/dev/null || true
        fi
        ;;
    esac

    sleep "$GPU_WAIT_STEP"
    waited=$((waited + GPU_WAIT_STEP))
  done
  return 1
}

set_target_gen() {
  bdf="$1"
  lc2=$(setpci -s "$bdf" CAP_EXP+30.L 2>/dev/null || true)
  [ -n "$lc2" ] || return 0
  lc2_new=$(printf "%08x" $(( (0x$lc2 & 0xfffffff0) | TARGET_GEN )))
  setpci -s "$bdf" CAP_EXP+30.L="$lc2_new" 2>/dev/null || true
}

disable_aspm() {
  bdf="$1"
  lc=$(setpci -s "$bdf" CAP_EXP+10.L 2>/dev/null || true)
  [ -n "$lc" ] || return 0
  lc_new=$(printf "%08x" $((0x$lc & 0xfffffffc)))
  setpci -s "$bdf" CAP_EXP+10.L="$lc_new" 2>/dev/null || true
  setpci -s "$bdf" 0x50.B=0x40 2>/dev/null || true
}

retrain_link() {
  bdf="$1"
  lc=$(setpci -s "$bdf" CAP_EXP+10.L 2>/dev/null || true)
  [ -n "$lc" ] || return 0
  setpci -s "$bdf" CAP_EXP+10.L=$(printf "%08x" $((0x$lc | 0x20))) 2>/dev/null || true
}

bridge_path_for_gpu() {
  dev_path=$(readlink -f "/sys/bus/pci/devices/$1")
  printf '%s\n' "$dev_path" | tr '/' '\n' | grep -E '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$' | while read -r bdf; do
    [ "$bdf" = "$1" ] && continue
    class=$(cat "/sys/bus/pci/devices/$bdf/class" 2>/dev/null || true)
    case "$class" in 0x0604*) printf '%s\n' "$bdf" ;; esac
  done
}

configure_path() {
  gpu_bdf="$1"
  for bdf in $(bridge_path_for_gpu "$gpu_bdf") "$gpu_bdf"; do
    log "Keep awake, disable ASPM, set PCIe target Gen${TARGET_GEN}: $bdf"
    keep_awake "$bdf"
    disable_aspm "$bdf"
    set_target_gen "$bdf"
  done
}

set_nvidia_power_policy() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi -pm 1 >/dev/null 2>&1 || true
}

GPU_BDF=$(wait_for_gpu || true)

if [ -z "$GPU_BDF" ]; then
  log "NVIDIA eGPU not found; leaving system untouched"
  exit 0
fi

log "GPU: $GPU_BDF initial link: $(link_speed "$GPU_BDF")"

keep_awake "$GPU_BDF"

if ! bar0_valid "$GPU_BDF"; then
  log "BAR0 not assigned; skip PCIe speed forcing and NVIDIA probe"
  exit 0
fi

if [ -e "/sys/bus/pci/devices/$GPU_BDF/driver" ]; then
  log "Driver already bound: $(basename "$(readlink "/sys/bus/pci/devices/$GPU_BDF/driver")"); configure path, skip retrain"
  configure_path "$GPU_BDF"
  set_nvidia_power_policy
  log "GPU: $GPU_BDF bound-driver configured link: $(link_speed "$GPU_BDF")"
  exit 0
fi

configure_path "$GPU_BDF"

# Retrain from closest upstream bridge first, then endpoint as fallback.
last_bridge=$(bridge_path_for_gpu "$GPU_BDF" | tail -n 1)
[ -n "$last_bridge" ] && retrain_link "$last_bridge"
retrain_link "$GPU_BDF"
sleep 2

log "GPU: $GPU_BDF post-force link: $(link_speed "$GPU_BDF")"

modprobe -i nvidia 2>/dev/null || true
modprobe -i nvidia_modeset 2>/dev/null || true
modprobe -i nvidia_uvm 2>/dev/null || true
modprobe -i nvidia_drm 2>/dev/null || true

sleep 2
log "GPU: $GPU_BDF final link: $(link_speed "$GPU_BDF")"

set_nvidia_power_policy

GPU_BDF_AFTER=$(find_gpu || true)
if [ -n "$GPU_BDF_AFTER" ]; then
  configure_path "$GPU_BDF_AFTER"
  log "GPU: $GPU_BDF_AFTER post-bind configured link: $(link_speed "$GPU_BDF_AFTER")"
fi

exit 0
