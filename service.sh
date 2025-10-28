#!/system/bin/sh

# Wait for boot to complete
while [ -z "$(getprop sys.boot_completed)" ]; do sleep 1; done

# Get thermal services
thermal() {
    for d in /system/etc/init /vendor/etc/init /odm/etc/init; do
        [ -d "$d" ] && find "$d" -type f 2>/dev/null | xargs grep -h "^service" | awk '{print $2}' | grep thermal
    done
}

# Stop thermal services
for svc in $(thermal) android.hardware.thermal-service.mediatek android.hardware.thermal@2.0-service.mtk thermal thermald thermal_core thermal_manager vendor.thermal-hal-2-0.mtk mi_thermald vendor.thermal-engine vendor.thermal-manager vendor.thermal-hal-2-0 vendor.thermal-symlinks vendor.thermal.link_ready vendor.thermal.symlinks thermal_mnt_hal_service vendor.thermal-hal thermalloadalgod thermalservice sec-thermal-1-0 debug_pid.sec-thermal-1-0 thermal-engine vendor.thermal-hal-1-0 android.thermal-hal vendor-thermal-1-0 thermal-hal android.thermal-hal; do
    stop "$svc" 2>/dev/null
    pid=$(pidof "$svc") && [ -n "$pid" ] && kill -SIGSTOP "$pid"
done

# Reset init.svc properties
for prop in $(getprop | awk -F '[][]' '/init\.svc_/ {print $2}'); do
    [ -n "$prop" ] && resetprop -n "$prop" ""
done

# Stop thermal init.svc properties
for prop in $(getprop | grep thermal | cut -f1 -d] | cut -f2 -d[ | grep -F init.svc.); do
    setprop "$prop" stopped
done

# Disable thermal zones
if [ -d "/sys/class/thermal" ]; then
    for f in /sys/class/thermal/thermal_zone*/mode; do
        [ -f "$f" ] && chmod 644 "$f" && echo "disabled" > "$f"
    done
    for f in /sys/class/thermal/thermal_zone*/policy; do
        [ -f "$f" ] && echo "userspace" > "$f"
    done
    for zone in thermal_zone0 thermal_zone9 thermal_zone10; do
        f="/sys/class/thermal/$zone/trip_point_0_temp"
        [ -f "$f" ] && echo 999999999 > "$f"
    done
fi

# Disable GPU power limits
if [ -f "/proc/gpufreq/gpufreq_power_limited" ]; then
    for setting in ignore_batt_oc ignore_batt_percent ignore_low_batt ignore_thermal_protect ignore_pbm_limited; do
        echo "$setting 1" > /proc/gpufreq/gpufreq_power_limited
    done
fi

# Set CPU limits
if [ -d "/sys/devices/virtual/thermal/thermal_message" ]; then
    for cpu in 0 2 4 6 7; do
        f="/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq"
        [ -f "$f" ] && maxfreq=$(cat "$f") && [ -n "$maxfreq" ] && [ "$maxfreq" -gt 0 ] && echo "cpu$cpu $maxfreq" > /sys/devices/virtual/thermal/thermal_message/cpu_limits
    done
fi

# Disable PPM limits
if [ -d "/proc/ppm" ] && [ -f "/proc/ppm/policy_status" ]; then
    for idx in $(grep -E 'FORCE_LIMIT|PWR_THRO|THERMAL' /proc/ppm/policy_status | awk -F'[][]' '{print $2}'); do
        echo "$idx 0" > /proc/ppm/policy_status
    done
fi

# Hide thermal monitoring
[ -d "/sys/devices/virtual/thermal" ] && find /sys/devices/virtual/thermal -type f -exec chmod 000 {} +

# Disable thermal stats
command -v cmd >/dev/null 2>&1 && cmd thermalservice override-status 0

# Disable battery overcharge throttling
[ -f "/proc/mtk_batoc_throttling/battery_oc_protect_stop" ] && echo "stop 1" > /proc/mtk_batoc_throttling/battery_oc_protect_stop

# Disable workqueue power efficiency
[ -f "/sys/module/workqueue/parameters/power_efficient" ] && echo "N" > /sys/module/workqueue/parameters/power_efficient
[ -f "/sys/module/workqueue/parameters/disable_numa" ] && echo "N" > /sys/module/workqueue/parameters/disable_numa

# Auto charging cutoff
autocut() {
    while true; do
        if [ -f /sys/class/power_supply/battery/status ] && [ -f /sys/class/power_supply/battery/capacity ]; then
            CHARGE_STATUS=$(cat /sys/class/power_supply/battery/status)
            LEVEL=$(cat /sys/class/power_supply/battery/capacity)
        else
            sleep 5; continue
        fi
        
        command -v dumpsys >/dev/null 2>&1 && SCREEN_STATE=$(dumpsys nfc | grep 'mScreenState' | cut -d'=' -f2) || SCREEN_STATE="UNKNOWN"
        sleep 5
        
        if [ -f /sys/class/power_supply/charger/online ]; then
            if [ "$LEVEL" -gt 99 ]; then
                echo 0 > /sys/class/power_supply/charger/online
            elif [ "$LEVEL" -lt 1 ]; then
                echo 1 > /sys/class/power_supply/charger/online
                sleep 60
            fi
        fi
    done
}

# Start autocut in background
[ -d "/sys/class/power_supply/battery" ] && autocut &