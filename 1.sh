#!/bin/sh
# 15.1 终极版 激进模式 - 新设备伪装 + 特定应用清理

if [ -z "$GLOBAL_PENETRATE" ]; then
    export GLOBAL_PENETRATE=1
    BB_NS="nsenter"
    for p in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$p" ]; then BB_NS="$p nsenter"; break; fi
    done
    
    if $BB_NS -t 1 -m ls / >/dev/null 2>&1 && [ -f "$0" ]; then
        exec $BB_NS -t 1 -m sh "$0" "$@"
        exit 0
    fi
fi

export PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:/debug_ramdisk:$PATH"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.conf"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
[ -z "$EXPIRE_DATE" ] && EXPIRE_DATE=""

if [ -n "$EXPIRE_DATE" ] && echo "$EXPIRE_DATE" | grep -Eq '^[0-9]{8}$'; then
    TODAY=$(date '+%Y%m%d' 2>/dev/null)
    if [ -n "$TODAY" ] && [ "$TODAY" -gt "$EXPIRE_DATE" ]; then
        printf '%s\n' '卡密到期，不运行脚本'
        exit 0
    fi
fi

setenforce 0

SCRIPT_TAG="Tomato15.1"
CMP_TMP_DIR="/data/local/tmp/.tomato_cmp_$$"
BEFORE_FILE="$CMP_TMP_DIR/before.state"
AFTER_FILE="$CMP_TMP_DIR/after.state"

cleanup_script() {
    setenforce 1
    [ -n "$CMP_TMP_DIR" ] && rm -rf "$CMP_TMP_DIR" >/dev/null 2>&1
}
trap 'cleanup_script' EXIT HUP INT TERM

WAIT_COUNT=0
until [ -d "/data/media/0/Android" ] || [ $WAIT_COUNT -gt 30 ]; do 
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 1))
done
sleep 3

TARGET="/mnt/vendor/persist"
[ ! -d "$TARGET" ] && [ -d "/persist" ] && TARGET="/persist"

RAM_MOUNT="/mnt/fix_ace_core"

SUSFS_BIN=""
for path in \
    "/data/adb/modules/ksu_susfs/tools/susfs_tool" \
    "/data/adb/ksu/bin/ksu_susfs" \
    "/data/adb/ap/bin/susfs_tool" \
    "/system/bin/susfs_tool"; do
    if [ -f "$path" ]; then SUSFS_BIN="$path"; break; fi
done

RP="resetprop"
if [ -f "/data/adb/magisk/magisk" ]; then RP="/data/adb/magisk/magisk resetprop"; fi
if [ -f "/data/adb/ksu/bin/resetprop" ]; then RP="/data/adb/ksu/bin/resetprop"; fi
if [ -f "/data/adb/ap/bin/resetprop" ]; then RP="/data/adb/ap/bin/resetprop"; fi
    if [ -f "/data/cache/resetprop" ]; then RP="/data/cache/resetprop"; fi

print_log() {
    printf '%s\n' "$*"
    if command -v log >/dev/null 2>&1; then
        log -t "$SCRIPT_TAG" "$*"
    fi
}


normalize_value() {
    if [ -n "$1" ]; then
        printf '%s' "$1"
    else
        printf '<empty>'
    fi
}

read_prop_value() {
    VALUE=$(getprop "$1" 2>/dev/null | tr -d '\r\n')
    normalize_value "$VALUE"
}

read_file_value() {
    if [ -f "$1" ]; then
        VALUE=$(head -n 1 "$1" 2>/dev/null | tr -d '\r\n')
        normalize_value "$VALUE"
    else
        printf '<missing>'
    fi
}

read_cmdline_field() {
    VALUE=$(sed -n "s/.*$1=\\([^ ]*\\).*/\\1/p" /proc/cmdline 2>/dev/null | head -n 1 | tr -d '\r\n')
    if [ -n "$VALUE" ]; then
        printf '%s' "$VALUE"
    else
        printf '<missing>'
    fi
}

read_cpuinfo_serial() {
    VALUE=$(awk -F: '/^Serial/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null | tr -d '\r\n')
    if [ -n "$VALUE" ]; then
        printf '%s' "$VALUE"
    else
        printf '<missing>'
    fi
}

read_secure_setting_user0() {
    VALUE=$(settings get secure --user 0 "$1" 2>/dev/null | tr -d '\r\n')
    normalize_value "$VALUE"
}

find_battery_dir() {
    for d in /sys/class/power_supply/battery /sys/class/power_supply/bms /sys/class/power_supply/main; do
        if [ -f "$d/serial_number" ]; then
            printf '%s' "$d"
            return
        fi
    done
}

find_ufs_dir() {
    for d in sda sdb sdc mmcblk0; do
        if [ -d "/sys/class/block/$d/device" ]; then
            printf '%s' "/sys/class/block/$d/device"
            return
        fi
    done
}

find_panel_path() {
    for panel in /sys/class/drm/card0-DSI-1/panel_serial_number /sys/class/graphics/fb0/msm_fb_panel_info /sys/class/graphics/fb0/panel_serial_number; do
        if [ -f "$panel" ]; then
            printf '%s' "$panel"
            return
        fi
    done
}

read_ssaid_value() {
    if [ -f "/data/system/users/0/settings_ssaid.xml" ]; then
        VALUE=$(sed -n 's/.*value="\([a-f0-9]\{16\}\)".*/\1/p' /data/system/users/0/settings_ssaid.xml 2>/dev/null | head -n 1 | tr -d '\r\n')
        if [ -n "$VALUE" ]; then
            printf '%s' "$VALUE"
        else
            printf '<missing>'
        fi
    else
        printf '<missing>'
    fi
}

append_snapshot() {
    printf '%s|%s\n' "$1" "$2" >> "$3"
}

snapshot_state() {
    OUT_FILE="$1"
    : > "$OUT_FILE"

    append_snapshot "ro.serialno" "$(read_prop_value ro.serialno)" "$OUT_FILE"
    append_snapshot "ro.boot.serialno" "$(read_prop_value ro.boot.serialno)" "$OUT_FILE"
    append_snapshot "ro.build.type" "$(read_prop_value ro.build.type)" "$OUT_FILE"
    append_snapshot "ro.build.tags" "$(read_prop_value ro.build.tags)" "$OUT_FILE"
    append_snapshot "ro.boot.verifiedbootstate" "$(read_prop_value ro.boot.verifiedbootstate)" "$OUT_FILE"
    append_snapshot "ro.boot.flash.locked" "$(read_prop_value ro.boot.flash.locked)" "$OUT_FILE"
    append_snapshot "ro.boot.vbmeta.device_state" "$(read_prop_value ro.boot.vbmeta.device_state)" "$OUT_FILE"
    append_snapshot "ro.secure" "$(read_prop_value ro.secure)" "$OUT_FILE"
    append_snapshot "ro.debuggable" "$(read_prop_value ro.debuggable)" "$OUT_FILE"
    append_snapshot "sys.usb.state" "$(read_prop_value sys.usb.state)" "$OUT_FILE"
    append_snapshot "cpuinfo.serial" "$(read_cpuinfo_serial)" "$OUT_FILE"
    append_snapshot "cmdline.serialno" "$(read_cmdline_field androidboot.serialno)" "$OUT_FILE"
    append_snapshot "cmdline.verifiedbootstate" "$(read_cmdline_field androidboot.verifiedbootstate)" "$OUT_FILE"
    append_snapshot "settings.android_id.user0" "$(read_secure_setting_user0 android_id)" "$OUT_FILE"
    append_snapshot "settings.bluetooth.user0" "$(read_secure_setting_user0 bluetooth_address)" "$OUT_FILE"
    append_snapshot "wlan0.address" "$(read_file_value /sys/class/net/wlan0/address)" "$OUT_FILE"
    append_snapshot "usb.iSerial" "$(read_file_value /sys/class/android_usb/android0/iSerial)" "$OUT_FILE"

    BT_VALUE="<missing>"
    for bt_file in "$RAM_MOUNT/bluetooth/.mac" "$RAM_MOUNT/bda/bdaddr" "$TARGET/bluetooth/.mac" "$TARGET/bda/bdaddr"; do
        if [ -f "$bt_file" ]; then
            BT_VALUE=$(read_file_value "$bt_file")
            break
        fi
    done
    append_snapshot "persist.bt_mac" "$BT_VALUE" "$OUT_FILE"

    BATT_PATH=$(find_battery_dir)
    if [ -n "$BATT_PATH" ]; then
        append_snapshot "battery.serial_number" "$(read_file_value "$BATT_PATH/serial_number")" "$OUT_FILE"
        append_snapshot "battery.cycle_count" "$(read_file_value "$BATT_PATH/cycle_count")" "$OUT_FILE"
    else
        append_snapshot "battery.serial_number" "<missing>" "$OUT_FILE"
        append_snapshot "battery.cycle_count" "<missing>" "$OUT_FILE"
    fi

    UFS_PATH=$(find_ufs_dir)
    if [ -n "$UFS_PATH" ]; then
        append_snapshot "ufs.cid" "$(read_file_value "$UFS_PATH/cid")" "$OUT_FILE"
        append_snapshot "ufs.serial" "$(read_file_value "$UFS_PATH/serial")" "$OUT_FILE"
    else
        append_snapshot "ufs.cid" "<missing>" "$OUT_FILE"
        append_snapshot "ufs.serial" "<missing>" "$OUT_FILE"
    fi

    append_snapshot "soc.serial_number" "$(read_file_value /sys/devices/soc0/serial_number)" "$OUT_FILE"

    PANEL_PATH=$(find_panel_path)
    if [ -n "$PANEL_PATH" ]; then
        append_snapshot "panel.serial" "$(read_file_value "$PANEL_PATH")" "$OUT_FILE"
    else
        append_snapshot "panel.serial" "<missing>" "$OUT_FILE"
    fi

    append_snapshot "settings_ssaid" "$(read_ssaid_value)" "$OUT_FILE"
}

print_snapshot() {
    TITLE="$1"
    STATE_FILE="$2"
    print_log "========== $TITLE =========="
    while IFS='|' read -r KEY VALUE; do
        print_log "$(printf '%-30s %s' "$KEY" "$VALUE")"
    done < "$STATE_FILE"
}

get_snapshot_value() {
    LOOKUP_KEY="$1"
    STATE_FILE="$2"
    awk -F'|' -v key="$LOOKUP_KEY" '$1 == key { print substr($0, index($0, "|") + 1); exit }' "$STATE_FILE"
}

print_snapshot_diff() {
    BEFORE_STATE="$1"
    AFTER_STATE="$2"
    print_log "========== BEFORE/AFTER DIFF =========="
    while IFS='|' read -r KEY BEFORE_VALUE; do
        AFTER_VALUE=$(get_snapshot_value "$KEY" "$AFTER_STATE")
        [ -z "$AFTER_VALUE" ] && AFTER_VALUE="<missing>"
        if [ "$BEFORE_VALUE" = "$AFTER_VALUE" ]; then
            STATUS="SAME"
        else
            STATUS="CHANGED"
        fi
        print_log "$(printf '[%s] %-30s %s -> %s' "$STATUS" "$KEY" "$BEFORE_VALUE" "$AFTER_VALUE")"
    done < "$BEFORE_STATE"
}


mkdir -p "$CMP_TMP_DIR" >/dev/null 2>&1
snapshot_state "$BEFORE_FILE"
print_snapshot "EXEC BEFORE" "$BEFORE_FILE"

# 定义随机值生成函数（在使用前必须定义）
rand_hex() {
	local count=${1:-1} result="" i=0 c lookup="0123456789abcdef"
	while [ $i -lt $count ]; do
		c=$((RANDOM % 16))
		result="${result}${lookup:$c:1}"
		i=$((i + 1))
	done
	echo "$result"
}
rand_alnum() {
	local count=${1:-1} result="" i=0 c lookup="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	while [ $i -lt $count ]; do
		c=$((RANDOM % 36))
		result="${result}${lookup:$c:1}"
		i=$((i + 1))
	done
	echo "$result"
}
rand_digit() {
	local count=${1:-1} result="" i=0
	while [ $i -lt $count ]; do
		result="${result}$((RANDOM % 10))"
		i=$((i + 1))
	done
	echo "$result"
}

get_random_date() {
    local Y=$((2023 + RANDOM % 2))
    local m=$(printf "%02d" $(((RANDOM % 12) + 1)))
    local d=$(printf "%02d" $(((RANDOM % 28) + 1)))
    local H=$(printf "%02d" $((RANDOM % 24)))
    local M=$(printf "%02d" $((RANDOM % 60)))
    echo "${Y}${m}${d}${H}${M}"
}

TARGET_PKGS="com.tencent.mf.uam com.tencent.tmgp.dfm com.tencent.tmgp.pubgmhd"

for PKG in $TARGET_PKGS; do
    rm -rf /data/data/$PKG/shared_prefs/* 2>/dev/null
    rm -rf /data/data/$PKG/databases/* 2>/dev/null
    rm -rf /data/data/$PKG/files/turingfd/* 2>/dev/null
    rm -rf /data/data/$PKG/files/beacon/* 2>/dev/null
    rm -rf /data/data/$PKG/files/tgpa/* 2>/dev/null
    rm -rf /data/data/$PKG/files/mid/* 2>/dev/null
    
    rm -rf /data/media/0/Android/data/$PKG/files/turingfd 2>/dev/null
    rm -rf /data/media/0/Android/data/$PKG/files/beacon 2>/dev/null
    rm -rf /data/media/0/Android/data/$PKG/cache/* 2>/dev/null
done

rm -rf /data/media/0/.turingfd 2>/dev/null
rm -rf /data/media/0/.backups 2>/dev/null
rm -rf /data/media/0/Tencent/.mta 2>/dev/null
rm -rf /data/media/0/Tencent/msflogs 2>/dev/null

# 计算伪新设备启动时间（距今 3-7 天内）
DAYS_AGO=$((3 + $(rand_digit 1) % 5))
NEW_BOOT_TIME=$(($(date +%s) - (DAYS_AGO * 86400)))

# ========== 激进模式：新设备标识重置 ==========
# GSF ID 是应用判定"新设备"最关键的依据
# 重置后 Google 服务会将此设备视为全新设备重新注册
print_log "========== 重置 GSF/GMS 设备标识 =========="

GSF_DIR="/data/data/com.google.android.gsf"
if [ -d "$GSF_DIR" ]; then
	rm -rf "$GSF_DIR/shared_prefs/CheckinService"* 2>/dev/null
	rm -rf "$GSF_DIR/databases/googlesettings.db"* 2>/dev/null
	print_log "GSF checkin 已清除（新设备注册标识）"
fi

GMS_DIR="/data/data/com.google.android.gms"
if [ -d "$GMS_DIR" ]; then
	rm -rf "$GMS_DIR/shared_prefs/CheckinService"* 2>/dev/null
	rm -rf "$GMS_DIR/files/gmscore_device"* 2>/dev/null
	print_log "GMS 设备注册信息已清除"
fi

# 重置 Google 广告 ID
settings put global advertising_id "" 2>/dev/null

# 重置目标应用的运行时权限（仅影响 TARGET_PKGS）
for PKG in $TARGET_PKGS; do
	pm reset-permissions "$PKG" 2>/dev/null
done
print_log "目标应用权限已重置"

# 随机化目标应用的安装/数据目录时间戳
for PKG in $TARGET_PKGS; do
	PKG_DIR="/data/data/$PKG"
	if [ -d "$PKG_DIR" ]; then
		RAND_TS=$((NEW_BOOT_TIME + RANDOM % 86400))
		FMT_TS=$(date -d "@$RAND_TS" '+%Y%m%d%H%M.%S' 2>/dev/null || date -jf '%s' "$RAND_TS" '+%Y%m%d%H%M.%S' 2>/dev/null)
		[ -n "$FMT_TS" ] && touch -t "$FMT_TS" "$PKG_DIR" 2>/dev/null
	fi
done
print_log "目标应用安装时间戳已随机化"

# 标记为新设备状态
setprop ro.build.date.utc "$NEW_BOOT_TIME" 2>/dev/null

# 设置首启相关时间戳
touch -t "$(date -d @$NEW_BOOT_TIME '+%Y%m%d%H%M.%S' 2>/dev/null || date -jf '%s' $NEW_BOOT_TIME '+%Y%m%d%H%M.%S' 2>/dev/null)" /data/system/.new_device_marker 2>/dev/null

# 标记首启完成时间为新时间
mkdir -p /data/system >/dev/null 2>&1
echo "$NEW_BOOT_TIME" > /data/system/.device_init_time 2>/dev/null

print_log "新设备初始化完成（启动时间: $DAYS_AGO 天前）"


spoof_sysfile() {
    local fake_file="$1"
    local real_path="$2"
    local content="$3"

    [ -n "$content" ] && echo "$content" > "$fake_file"
    chmod 444 "$fake_file"
    mount --bind "$fake_file" "$real_path" 2>/dev/null
    [ -n "$SUSFS_BIN" ] && "$SUSFS_BIN" add_sus_mount "$real_path" >/dev/null 2>&1
}


spoof_device_attr() {
    local fake_file="$1"
    local device_attr="$2"
    local content="$3"
    
    echo "$content" > "$fake_file"
    chmod 444 "$fake_file"
    mount --bind "$fake_file" "$device_attr" 2>/dev/null
    [ -n "$SUSFS_BIN" ] && "$SUSFS_BIN" add_sus_mount "$device_attr" >/dev/null 2>&1
}



umount -l "$RAM_MOUNT" >/dev/null 2>&1
rm -rf "$RAM_MOUNT" >/dev/null 2>&1
mkdir -p "$RAM_MOUNT"

PERSIST_CTX=$(ls -Zd "$TARGET" 2>/dev/null | awk '{print $1}')
[ -z "$PERSIST_CTX" ] && PERSIST_CTX="u:object_r:persist_file:s0"

mount -t tmpfs -o size=100M,mode=0755,context="$PERSIST_CTX" tmpfs "$RAM_MOUNT"
cp -a "$TARGET/." "$RAM_MOUNT/" 2>/dev/null

for dir in sensors camera audio data rfs bms display; do
    if [ -d "$RAM_MOUNT/$dir" ]; then
        chmod 755 "$RAM_MOUNT/$dir"
        chcon "$PERSIST_CTX" "$RAM_MOUNT/$dir"
        touch -t "$(get_random_date)" "$RAM_MOUNT/$dir"
    fi
done

FAKE_FILE="$RAM_MOUNT/sensors/sensors_settings"
if [ -d "$RAM_MOUNT/sensors" ]; then
    echo -n "$(rand_hex 64)" > "$FAKE_FILE"
    chcon "$PERSIST_CTX" "$FAKE_FILE"
    touch -t "$(get_random_date)" "$FAKE_FILE"
fi

mount --bind "$RAM_MOUNT" "$TARGET"

ORIG_SN=$(getprop ro.serialno)
[ -z "$ORIG_SN" ] && ORIG_SN=$(getprop ro.boot.serialno)
SN_LEN=${#ORIG_SN}; [ "$SN_LEN" -lt 6 ] && SN_LEN=10
NEW_SERIAL=$(rand_alnum "$SN_LEN")
NEW_AID=$(rand_hex 16)

mkdir -p "$RAM_MOUNT/sys_fake"

# Spoof /proc/cpuinfo
cpuinfo_file="$RAM_MOUNT/sys_fake/cpuinfo"
cat /proc/cpuinfo | sed "s/^Serial.*/Serial\t\t: $(rand_hex 16)/g" > "$cpuinfo_file"
spoof_sysfile "$cpuinfo_file" "/proc/cpuinfo" ""


spoof_device_file() {
    local device_path="$1"
    local fake_file="$2"
    local content="$3"
    
    if [ -f "$device_path" ]; then
        echo "$content" > "$fake_file"
        chmod 444 "$fake_file"
        mount --bind "$fake_file" "$device_path" 2>/dev/null
        [ -n "$SUSFS_BIN" ] && "$SUSFS_BIN" add_sus_mount "$device_path" >/dev/null 2>&1
        return 0
    fi
    return 1
}

# Spoof Battery
BATT_DIR=""
for d in /sys/class/power_supply/battery /sys/class/power_supply/bms /sys/class/power_supply/main; do
    if [ -f "$d/serial_number" ]; then BATT_DIR="$d"; break; fi
done

if [ -n "$BATT_DIR" ]; then
    ORIG_BATT=$(cat "$BATT_DIR/serial_number" 2>/dev/null | tr -d '\n')
    B_LEN=${#ORIG_BATT}; [ "$B_LEN" -lt 4 ] && B_LEN=10 
    spoof_device_file "$BATT_DIR/serial_number" "$RAM_MOUNT/sys_fake/batt_sn" "$(rand_alnum "$B_LEN")"
    
    if [ -f "$BATT_DIR/cycle_count" ]; then
        cycle=$((50 + $(rand_digit 2) % 200))
        spoof_device_file "$BATT_DIR/cycle_count" "$RAM_MOUNT/sys_fake/batt_cycle" "$cycle"
    fi
fi

# Spoof UFS/MMC
UFS_DIR=""
for d in sda sdb sdc mmcblk0; do
    if [ -d "/sys/class/block/$d/device" ]; then UFS_DIR="/sys/class/block/$d/device"; break; fi
done

if [ -n "$UFS_DIR" ]; then
    if [ -f "$UFS_DIR/cid" ]; then
        ORIG_CID=$(cat "$UFS_DIR/cid" 2>/dev/null | tr -d '\n')
        C_LEN=${#ORIG_CID}; [ "$C_LEN" -lt 16 ] && C_LEN=32
        spoof_device_file "$UFS_DIR/cid" "$RAM_MOUNT/sys_fake/ufs_cid" "$(rand_hex "$C_LEN")"
    fi
    if [ -f "$UFS_DIR/serial" ]; then
        ORIG_USN=$(cat "$UFS_DIR/serial" 2>/dev/null | tr -d '\n')
        S_LEN=${#ORIG_USN}; [ "$S_LEN" -lt 6 ] && S_LEN=16
        spoof_device_file "$UFS_DIR/serial" "$RAM_MOUNT/sys_fake/ufs_sn" "$(rand_alnum "$S_LEN")"
    fi
fi

# Spoof SoC
SOC_DIR="/sys/devices/soc0"
[ -f "$SOC_DIR/serial_number" ] && spoof_device_file "$SOC_DIR/serial_number" "$RAM_MOUNT/sys_fake/soc_sn" "$(rand_alnum 8)"

# Spoof Panel
for panel in /sys/class/drm/card0-DSI-1/panel_serial_number /sys/class/graphics/fb0/msm_fb_panel_info /sys/class/graphics/fb0/panel_serial_number; do
    spoof_device_file "$panel" "$RAM_MOUNT/sys_fake/panel_sn" "$(rand_hex 16)" && break
done

generate_fake_mac() {
    local oui_list="00:9a:cd 14:f6:5a 38:a4:ed 50:8a:06 08:1d:96 2c:5a:05 44:09:b8 08:22:38 10:30:47 1c:5a:3e 00:1e:10 04:52:f3"
    local index=$(( $(rand_digit 2) % 12 ))
    local oui=$(echo "$oui_list" | awk -v n=$((index + 1)) '{print $n}')
    local rest=$(rand_hex 6 | sed 's/\(..\)/:\1/g')
    echo "${oui}${rest}"
}

# Spoof USB Serial
USB_SERIAL="/sys/class/android_usb/android0/iSerial"
spoof_device_file "$USB_SERIAL" "$RAM_MOUNT/sys_fake/usb_serial" "$NEW_SERIAL"

for prop in ro.serialno ro.boot.serialno ro.sys.serialno ro.vendor.boot.serialno; do
    $RP -n "$prop" "$NEW_SERIAL"
done

$RP -n ro.build.type "user"
$RP -n ro.build.tags "release-keys"
$RP -n ro.boot.selinux "enforcing"
$RP -n ro.boot.verifiedbootstate "green"
$RP -n ro.boot.flash.locked "1"
$RP -n ro.boot.vbmeta.device_state "locked"
$RP -n ro.boot.warranty_bit "0"
$RP -n ro.debuggable "0"
$RP -n ro.secure "1"
$RP -n sys.usb.state "mtp"

FAKE_MAC=$(generate_fake_mac)
FAKE_BT_MAC=$(generate_fake_mac)

for bt_file in "$RAM_MOUNT/bluetooth/.mac" "$RAM_MOUNT/bda/bdaddr"; do
    if [ -f "$bt_file" ]; then
        echo "$FAKE_BT_MAC" > "$bt_file" 2>/dev/null
        chcon "$PERSIST_CTX" "$bt_file" 2>/dev/null
    fi
done
if [ -f "$RAM_MOUNT/wlan_mac.bin" ]; then
    echo "Intf0MacAddress=$FAKE_MAC" > "$RAM_MOUNT/wlan_mac.bin" 2>/dev/null
    echo "Intf1MacAddress=$FAKE_MAC" >> "$RAM_MOUNT/wlan_mac.bin" 2>/dev/null
    chcon "$PERSIST_CTX" "$RAM_MOUNT/wlan_mac.bin" 2>/dev/null
fi

MAC_FILE="/sys/class/net/wlan0/address"
if [ -f "$MAC_FILE" ]; then
    echo "$FAKE_MAC" > "$RAM_MOUNT/sys_fake/wlan_mac"
    chmod 444 "$RAM_MOUNT/sys_fake/wlan_mac"
    mount --bind "$RAM_MOUNT/sys_fake/wlan_mac" "$MAC_FILE" 2>/dev/null
    [ -n "$SUSFS_BIN" ] && "$SUSFS_BIN" add_sus_mount "$MAC_FILE" >/dev/null 2>&1
fi

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done


for user_id in 0 999; do
    settings put secure --user "$user_id" android_id "$NEW_AID" 2>/dev/null
    settings put secure --user "$user_id" bluetooth_address "$FAKE_BT_MAC" 2>/dev/null
done
settings put secure android_id "$NEW_AID" 2>/dev/null
settings put secure bluetooth_address "$FAKE_BT_MAC" 2>/dev/null
settings put global wifi_mac_randomization 1 2>/dev/null
settings put global wifi_non_persistent_mac_randomization 1 2>/dev/null

# Spoof SSAID
SSAID_FILE="/data/system/users/0/settings_ssaid.xml"
if [ -f "$SSAID_FILE" ]; then
    fake_ssaid="$RAM_MOUNT/sys_fake/settings_ssaid.xml"
    cp -a "$SSAID_FILE" "$fake_ssaid" 2>/dev/null
    sed -i "s/value=\"[a-f0-9]\{16\}\"/value=\"$NEW_AID\"/g" "$fake_ssaid" 2>/dev/null
    
    chmod 600 "$fake_ssaid"
    chown system:system "$fake_ssaid" 2>/dev/null
    chcon "u:object_r:system_data_file:s0" "$fake_ssaid" 2>/dev/null
    
    mount --bind "$fake_ssaid" "$SSAID_FILE" 2>/dev/null
    [ -n "$SUSFS_BIN" ] && "$SUSFS_BIN" add_sus_mount "$SSAID_FILE" >/dev/null 2>&1
fi

if [ -n "$SUSFS_BIN" ]; then
    for sus_mount in "$TARGET" "$SSAID_FILE" "$MAC_FILE"; do
        [ -n "$sus_mount" ] && "$SUSFS_BIN" add_sus_mount "$sus_mount" >/dev/null 2>&1
    done
    
    for try_umount in "$RAM_MOUNT" "/data/adb" "/data/adb/modules"; do
        "$SUSFS_BIN" add_try_umount "$try_umount" >/dev/null 2>&1
    done
    
    for sus_path in "$RAM_MOUNT" "/system/bin/su"; do
        "$SUSFS_BIN" add_sus_path "$sus_path" >/dev/null 2>&1
    done
    
    "$SUSFS_BIN" update_susfs_status 1 >/dev/null 2>&1
fi

snapshot_state "$AFTER_FILE"
print_snapshot "EXEC AFTER" "$AFTER_FILE"
print_snapshot_diff "$BEFORE_FILE" "$AFTER_FILE"

print_log "========== 新设备伪装完成（激进模式）=========="
print_log "目标应用数据已清理: $TARGET_PKGS"
print_log "硬件标识已伪装 (SN, MAC, SSAID 等)"
print_log "GSF/GMS 设备注册标识已重置"
print_log "广告 ID + 目标应用权限 + 安装时间戳已随机化"
print_log "========== 设备现以新身份运行 =========="

dmesg -c > /dev/null 2>&1

setenforce 1
exit 0
