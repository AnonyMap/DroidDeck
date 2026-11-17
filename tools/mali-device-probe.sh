#!/usr/bin/env bash
# Collects the facts that decide a Mali device's graphics route, over plain adb (no root).
# Usage: tools/mali-device-probe.sh [--serial SERIAL] [--out DIR]
set -u
serial=${ANDROID_SERIAL:-}
out=.
while [ $# -gt 0 ]; do
  case $1 in
    --serial) serial=$2; shift ;;
    --out) out=$2; shift ;;
    -h|--help) sed -n 2,3p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
adb_cmd=(adb)
[ -n "$serial" ] && adb_cmd+=(-s "$serial")
"${adb_cmd[@]}" get-state >/dev/null 2>&1 || { echo "no device (adb get-state failed)" >&2; exit 2; }

model=$("${adb_cmd[@]}" shell getprop ro.product.model | tr -d '\r' | tr ' /' '__')
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
report="$out/mali-probe-$model-$stamp.txt"
vkjson="$out/mali-probe-$model-$stamp-vkjson.json"

sh_() { "${adb_cmd[@]}" shell "$@" 2>&1 | tr -d '\r'; }
section() { printf '\n== %s\n' "$1"; }

{
  section device
  for p in ro.product.manufacturer ro.product.model ro.build.version.release ro.build.version.sdk \
           ro.soc.manufacturer ro.soc.model ro.board.platform ro.hardware ro.product.board \
           ro.vendor.build.fingerprint ro.build.fingerprint; do
    printf '%s=%s\n' "$p" "$(sh_ getprop "$p")"
  done
  section kernel
  sh_ uname -a
  printf 'page_size=%s\n' "$(sh_ getconf PAGE_SIZE)"
  section cpu
  sh_ grep -m1 '^Features' /proc/cpuinfo
  printf 'lse2(uscat)=%s\n' "$(sh_ grep -c -w uscat /proc/cpuinfo)"
  sh_ cat /sys/devices/system/cpu/online
  sh_ 'for c in /sys/devices/system/cpu/cpu[0-9]*; do echo "$(basename $c) $(cat $c/regs/identification/midr_el1 2>/dev/null) $(cat $c/cpu_capacity 2>/dev/null) $(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null)"; done'
  section memory
  sh_ head -8 /proc/meminfo
  sh_ cat /proc/swaps
  section 'gpu nodes'
  sh_ ls -l /dev/mali0 /dev/dri /dev/dma_heap
  sh_ ls /vendor/lib64/hw | grep -i -E 'vulkan|gralloc|mali'
  sh_ ls /vendor/lib64/egl
  section 'mali driver (GLES string)'
  sh_ dumpsys SurfaceFlinger | grep -i -m3 -E 'GLES|mali'
  section 'vulkan features'
  sh_ pm list features | grep -i vulkan
  section 'kbase / ged (shell domain: the app may see less)'
  for f in /sys/class/misc/mali0/device/gpuinfo /sys/class/misc/mali0/device/core_mask \
           /sys/kernel/ged/hal/gpu_utilization /sys/kernel/ged/hal/current_freqency \
           /sys/kernel/ged/hal/gpu_clock /sys/module/ged/parameters/gpu_loading; do
    printf '%s: %s\n' "$f" "$(sh_ cat "$f" | head -3 | tr '\n' ' ')"
  done
  section thermal
  sh_ 'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type 2>/dev/null) $(cat $z/temp 2>/dev/null)"; done' | grep -i -E 'gpu|cpu|soc|mtk' | head -20
  section 'developer options that DroidDeck needs'
  printf 'settings_enable_monitor_phantom_procs=%s\n' "$(sh_ settings get global settings_enable_monitor_phantom_procs)"
  section droiddeck
  sh_ dumpsys package com.droiddeck.launcher | grep -m3 -E 'versionName|versionCode|firstInstallTime'
} > "$report"

"${adb_cmd[@]}" shell cmd gpu vkjson 2>/dev/null | tr -d '\r' > "$vkjson"
if [ -s "$vkjson" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$vkjson" >> "$report" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"\n== vkjson: could not parse ({e})"); sys.exit(0)
devices = data.get("devices") or [data]
for d in devices:
    props = d.get("properties", {})
    api = props.get("apiVersion", 0)
    print("\n== vkjson device")
    print("name=%s api=%d.%d.%d driverVersion=0x%x" % (props.get("deviceName"), api >> 22, (api >> 12) & 0x3ff, api & 0xfff, props.get("driverVersion", 0)))
    drv = d.get("driverProperties") or d.get("properties11", {})
    if isinstance(drv, dict) and drv.get("driverInfo"):
        print("driverInfo=%s" % drv.get("driverInfo"))
    feats = d.get("features", {})
    for k in ["multiDrawIndirect", "fillModeNonSolid", "multiViewport", "shaderClipDistance", "shaderCullDistance",
              "textureCompressionBC", "textureCompressionETC2", "geometryShader", "tessellationShader",
              "robustBufferAccess", "shaderInt64", "shaderFloat64", "depthClamp", "independentBlend"]:
        print("%s=%s" % (k, feats.get(k)))
    exts = sorted(e.get("extensionName", "") for e in d.get("extensions", []))
    for k in ["VK_EXT_robustness2", "VK_KHR_dynamic_rendering", "VK_KHR_push_descriptor", "VK_EXT_external_memory_dma_buf",
              "VK_EXT_image_drm_format_modifier", "VK_KHR_external_semaphore_fd", "VK_EXT_transform_feedback",
              "VK_EXT_custom_border_color", "VK_KHR_timeline_semaphore", "VK_EXT_extended_dynamic_state3"]:
        print("%s=%s" % (k, "yes" if k in exts else "no"))
    mem = d.get("memory", {})
    for i, t in enumerate(mem.get("memoryTypes", [])):
        print("memtype %d heap %s flags 0x%x" % (i, t.get("heapIndex"), t.get("propertyFlags", 0)))
    for i, h in enumerate(mem.get("memoryHeaps", [])):
        print("heap %d size %.0f MiB flags 0x%x" % (i, h.get("size", 0) / 1048576, h.get("flags", 0)))
PY
fi
echo "wrote $report"
[ -s "$vkjson" ] && echo "wrote $vkjson"
