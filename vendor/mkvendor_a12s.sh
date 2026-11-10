#!/bin/bash
# usage: sudo CC=<ndk clang> mkvendor_a12s.sh <a12s stock vendor files> <xcover5 stock vendor files> <A14 stock vendor.img (erofs)> <out.img>
set -euo pipefail

[ $# -eq 4 ] || { sed -n 2p "$0" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "run as root (xattrs)" >&2; exit 1; }
for t in fsck.erofs mkfs.erofs dump.erofs setfattr getfattr readelf patchelf python3 "${CC:?CC is not set}"; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

A12S=$(realpath "$1")
XC5=$(realpath "$2")
A14_IMG=$(realpath "$3")
OUT_IMG=$(realpath -m "$4")
KIT=$(dirname "$(realpath "$0")")

WORK=$(mktemp -d /var/tmp/mkvendor_a12s.XXXX)
TREE=$WORK/vendor
trap 'rm -rf "$WORK"' EXIT

label() { setfattr -n security.selinux -v "u:object_r:$1:s0" "$2"; }
own_lib() { chown 0:0 "$TREE/$1"; chmod 644 "$TREE/$1"; label "$2" "$TREE/$1"; }
# shim_cc <target> <soname> <output> <cc args...>
shim_cc() {
    local target=$1 soname=$2 out=$3; shift 3
    "$CC" --target="$target" -shared -fPIC -O2 -Wall -Werror -Wl,-soname,"$soname" -o "$out" "$@"
}

fsck.erofs --extract="$TREE" --xattrs --preserve --overwrite "$A14_IMG"

a12s() { install -D -m "$2" -o 0 -g "$3" "$A12S/$1" "$TREE/$1"; label "$4" "$TREE/$1"; }
# replaces an A14 file in place; cat keeps the inode label
a12s_over() { [ -f "$TREE/$2" ]; cat "$A12S/$1" > "$TREE/$2"; }
a12shal() {
    local exec_label=$1 libs; shift
    libs=$(python3 "$KIT/a12shal.py" "$A12S" "$TREE" "$@")
    a12s "$1" 755 2000 "$exec_label"
    for l in $libs; do a12s "lib64/$l" 644 0 vendor_file; done
}

# Every driver is built into the kernel
rm -f "$TREE"/lib/modules/*.ko

# Defex policy and the stock recovery restoration
rm -rf "$TREE/etc/dpolicy" \
       "$TREE/recovery-from-boot.p" \
       "$TREE/bin/install-recovery.sh" \
       "$TREE/etc/init/vendor_flash_recovery.rc"

# a12s partition layout: no vbmeta_system, vendor_dlkm, system_dlkm, init_boot or vendor_boot
cat "$KIT/fstab.s5e3830" > "$TREE/etc/fstab.s5e3830"

# a12s TEEGRIS cannot load the A14 KeyMint TA (no EVP_PKEY_get_raw_private_key), so KeyMint goes.
# xcover5 (A14 era, Keymaster 4.0 HIDL) ships the a12s Keymaster TA byte for byte; its HAL and the
# libs it was built with replace KeyMint. Only KeyMint used the A14 copies of those libs.
# Gatekeeper and its TA come from xcover5 as well, as on the xcover5 vendor that booted on a12s.
xc5() { install -D -m "$2" -o 0 -g "$3" "$XC5/$1" "$TREE/$1"; label "$4" "$TREE/$1"; }
xc5_over() { [ -f "$TREE/$1" ]; cat "$XC5/$1" > "$TREE/$1"; }
rm -f "$TREE/bin/hw/android.hardware.security.keymint-service" \
      "$TREE/etc/init/android.hardware.security.keymint-service.rc"
xc5 bin/hw/android.hardware.keymaster@4.0-service 755 2000 hal_keymaster_default_exec
xc5 etc/init/android.hardware.keymaster@4.0-service.rc 644 0 vendor_configs_file
for l in libkeymaster4.so libkeymaster_helper.so libskeymaster4device.so; do
    xc5 "lib64/$l" 644 0 vendor_file
done
for l in android.hardware.keymaster@3.0.so android.hardware.keymaster@4.0.so android.hardware.keymaster@4.1.so \
         libkeymaster4support.so libkeymaster4_1support.so libkeymaster_messages.so libkeymaster_portable.so \
         libpuresoftkeymasterdevice.so libsoft_attestation_cert.so libcppbor_external.so libcppcose_rkp.so \
         android.hardware.gatekeeper@1.0.so hw/android.hardware.gatekeeper@1.0-impl.so hw/gatekeeper.s5e3830.so; do
    xc5_over "lib64/$l"
done
for f in bin/hw/android.hardware.gatekeeper@1.0-service \
         tee/00000000-0000-0000-0000-4b45594d5354 tee/00000000-0000-0000-0000-474154454b45; do
    xc5_over "$f"
done
shim_cc aarch64-linux-android30 libcrypto_shim.so "$TREE/lib64/libcrypto_shim.so" "$KIT/crypto_shim.c"
patchelf --add-needed libcrypto.so "$TREE/lib64/libcrypto_shim.so"
own_lib lib64/libcrypto_shim.so vendor_file
for l in libkeymaster_helper.so libkeymaster_portable.so libkeymaster4support.so libkeymaster4_1support.so \
         libskeymaster4device.so; do
    cp "$TREE/lib64/$l" "$WORK/$l"
    patchelf --add-needed libcrypto_shim.so "$WORK/$l"
    cat "$WORK/$l" > "$TREE/lib64/$l"
done
python3 - "$TREE/etc/vintf/manifest.xml" "$TREE/tmp" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
drop = ("android.hardware.security.keymint", "android.hardware.security.secureclock",
        "android.hardware.security.sharedsecret", "vendor.samsung.hardware.keymint")
blocks = re.findall(r"\n *<hal [^>]*>.*?</hal>", s, re.S)
gone = [b for b in blocks if re.search(r"<name>(.*?)</name>", b).group(1) in drop]
assert len(gone) == 6, len(gone)
for b in gone:
    s = s.replace(b, "")
km = """    <hal format="hidl" override="true">
        <name>android.hardware.keymaster</name>
        <transport>hwbinder</transport>
        <fqname>@4.0::IKeymasterDevice/default</fqname>
    </hal>
"""
s = s.replace("</manifest>", km + "</manifest>", 1)
open(sys.argv[2], "w").write(s)
PY
cat "$TREE/tmp" > "$TREE/etc/vintf/manifest.xml"
rm "$TREE/tmp"

# a12s Goodix side key: the a12s HIDL fingerprint@3.0 HAL and its TA replace the A14 AIDL HAL
rm -f "$TREE/etc/vintf/manifest/vendor.samsung.hardware.biometrics.fingerprint-service.xml" \
      "$TREE/etc/init/vendor.samsung.hardware.biometrics.fingerprint-service.rc"
a12shal hal_fingerprint_default_exec bin/hw/vendor.samsung.hardware.biometrics.fingerprint@3.0-service lib64/hw/fingerprint.default.so
a12s lib64/hw/fingerprint.default.so 644 0 vendor_file
a12s etc/init/vendor.samsung.hardware.biometrics.fingerprint@3.0-service.rc 644 0 vendor_configs_file
a12s etc/vintf/manifest/vendor.samsung.hardware.biometrics.fingerprint@3.0-service.xml 644 0 vendor_configs_file
a12s_over tee/00000000-0000-0000-0000-46494e474502 tee/00000000-0000-0000-0000-46494e474502

# a12s NFC is NXP PN557 on the pn547 driver; the A14 Samsung S3NRN4V HAL is swapped for the a12s NXP HIDL HAL
rm -f "$TREE/etc/init/sec-nfc-service.rc" "$TREE/etc/vintf/manifest/sec-nfc-service.xml"
a12shal hal_nfc_default_exec bin/hw/nxp.android.hardware.nfc@1.2-service lib64/nfc_nci_nxpsn.so
a12s etc/init/nxp.android.hardware.nfc@1.2-service.rc 644 0 vendor_configs_file
a12s etc/vintf/manifest/nxp.android.hardware.nfc@1.2-service.xml 644 0 vendor_configs_file
a12s etc/libnfc-nxp.conf 644 0 vendor_configs_file
a12s etc/nfc/libnfc-nxp_RF.conf 644 0 vendor_configs_file
a12s firmware/nfc/libpn557_fw.so 644 0 vendor_fw_file

# The kernel refuses the legacy ../etc/wifi firmware name and has no lnk_file read on vendor_fw_file,
# so the WLBT set is copied to /vendor/firmware/wifi as on xcover5
[ ! -e "$TREE/firmware/wifi" ]
cp -a "$TREE/etc/wifi" "$TREE/firmware/wifi"
find "$TREE/firmware/wifi" -exec chown 0:0 {} + \
    -exec setfattr -n security.selinux -v u:object_r:vendor_fw_file:s0 {} +
find "$TREE/firmware/wifi" -type d -exec chmod 755 {} +
find "$TREE/firmware/wifi" -type f -exec chmod 644 {} +

# A14 camera HAL only knows A14 sensors; the a12s HAL, its plugins, DDK, RTA and setfiles are taken whole.
# The A14 HWL loads the legacy module as camera.<ro.hardware>.
# The A14 HWL camera_module_t has two more hooks before set_callbacks; camera_shim.c re-lays the a12s HMI.
a12s lib64/hw/camera.exynos850.so 644 0 vendor_file
shim_cc aarch64-linux-android30 camera.s5e3830.so "$WORK/camera.s5e3830.so" "$KIT/camera_shim.c" -llog
cat "$WORK/camera.s5e3830.so" > "$TREE/lib64/hw/camera.s5e3830.so"
for l in libexynoscamera3.so libexynoscamera_plugin.so libexynoscamera_plugin_utils.so libremosaic_wrapper.so \
         libsec2lsi_conversion.so libexynoscamera_tdnr_plugin.so libmfb.so; do
    a12s_over "lib64/$l" "lib64/$l"
done
a12s lib64/libremosaiclib_s5kgm2_cpu.so 644 0 vendor_file
for f in setfile_gm2.bin setfile_4ha.bin setfile_sr846.bin setfile_gc5035.bin setfile_gc02m1.bin setfile_gc02m1_macro.bin \
         tdnr_S5KGM2.json tdnr_S5K4HA.json tdnr_SR846.json tdnr_GC5035.json tdnr_GC02M1.json dual_cal_wide_sub.bin; do
    a12s "firmware/$f" 644 0 vendor_fw_file
done
for f in is_lib.bin is_rta.bin; do
    python3 "$KIT/ddk_rebase.py" "$A12S/firmware/$f" "$WORK/$f"
    cat "$WORK/$f" > "$TREE/firmware/$f"
done

shim_cc aarch64-linux-android30 libui_shim.so "$TREE/lib64/libui_shim.so" -Wl,-z,defs "$KIT/ui_shim.c" "$TREE/lib64/libui.so"
own_lib lib64/libui_shim.so vendor_file
cp "$TREE/lib64/libexynoscamera3.so" "$WORK/libexynoscamera3.so"
# On 5.10 (/dev/dma_heap) A14 libion_exynos exynos_ion_close() is a no-op; rewire dmabuf free calls to close().
python3 - "$WORK/libexynoscamera3.so" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
OLD, NEW = 0x283a00, 0x283a90
assert d[OLD:OLD + 16] == bytes.fromhex("700000d0113247f91082399120021fd6")
assert d[NEW:NEW + 16] == bytes.fromhex("700000d0115647f910a23a9120021fd6")
bl = lambda pc, dst: 0x94000000 | (((dst - pc) >> 2) & 0x3ffffff)
for pc in (0xf6bf4, 0xf838c, 0xf9874, 0x207564):
    assert struct.unpack_from("<I", d, pc)[0] == bl(pc, OLD), hex(pc)
    struct.pack_into("<I", d, pc, bl(pc, NEW))
# the remosaic PP takes its client from libion ion_open(), a real fd
ION_CLOSE = 0x284760
assert d[ION_CLOSE:ION_CLOSE + 16] == bytes.fromhex("700000d0118a42f91042149120021fd6")
for pc in (0x2781f0, 0x278674):
    assert struct.unpack_from("<I", d, pc)[0] == bl(pc, OLD), hex(pc)
    struct.pack_into("<I", d, pc, bl(pc, ION_CLOSE))
open(p, "wb").write(d)
PY
patchelf --add-needed libui_shim.so "$WORK/libexynoscamera3.so"
# The a12s HAL inlines the JPEG encoder setters; A14 libhwjpeg moved width/height 4 bytes down, xcover5 did not.
xc5 lib64/libgiantmscl.so 644 0 vendor_file
cp "$XC5/lib64/libhwjpeg.so" "$TREE/lib64/libhwjpeg_a12s.so"
# Its encoder is 8 bytes larger than the HAL allocates: the constructor and encode() zero the last appinfo slot,
# which is the pipe's debug buffer pointer or, for the JPEG node, past the end of a 1576 byte heap block.
python3 - "$TREE/lib64/libhwjpeg_a12s.so" <<'PY'
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
for off, old in ((0x10fac, "7f1603f9"), (0x11b50, "df1603f9"), (0x11c18, "ff1603f9")):
    assert d[off:off + 4] == bytes.fromhex(old), hex(off)
    d[off:off + 4] = bytes.fromhex("1f2003d5")
open(p, "wb").write(d)
PY
patchelf --set-soname libhwjpeg_a12s.so "$TREE/lib64/libhwjpeg_a12s.so"
own_lib lib64/libhwjpeg_a12s.so vendor_file
cp "$TREE/lib64/hw/camera.exynos850.so" "$WORK/camera.exynos850.so"
patchelf --replace-needed libhwjpeg.so libhwjpeg_a12s.so "$WORK/libexynoscamera3.so"
patchelf --replace-needed libhwjpeg.so libhwjpeg_a12s.so "$WORK/camera.exynos850.so"
cat "$WORK/camera.exynos850.so" > "$TREE/lib64/hw/camera.exynos850.so"
cat "$WORK/libexynoscamera3.so" > "$TREE/lib64/libexynoscamera3.so"

# Stock libion.so only knows /dev/ion, which this kernel does not have; the shim allocates from dma-buf heaps.
# It stays same_process_hal_file as in vendor_file_contexts: the mapper pulls it into app processes.
shim_cc aarch64-linux-android30 libion.so "$TREE/lib64/libion.so" -Wl,-z,defs "$KIT/ion_shim.c" -llog
own_lib lib64/libion.so same_process_hal_file
shim_cc armv7a-linux-androideabi30 libion.so "$TREE/lib/libion.so" -Wl,-z,defs "$KIT/ion_shim.c" -llog
own_lib lib/libion.so same_process_hal_file

# a12s has no proximity chip on the sensorhub, only the touch ear detect behind the Hover Proximity sensor.
# The A14 multihal list has no inputvirtual subhal, a12s loads it like the stock hals.conf
python3 "$KIT/proxhal_patch.py" "$TREE/lib64/sensors.inputvirtual.so" "$WORK/sensors.inputvirtual.so"
cat "$WORK/sensors.inputvirtual.so" > "$TREE/lib64/sensors.inputvirtual.so"
hc=$TREE/etc/sensors/hals.conf
grep -q inputvirtual "$hc" || printf '\n/vendor/lib64/sensors.inputvirtual.so\n' >> "$hc"
grep -v '^$' "$hc" > "$TREE/tmp"
cat "$TREE/tmp" > "$hc"
rm "$TREE/tmp"

# a12s has no ambient light chip on the sensorhub, CameraLightSensor uses this EV-Lux table
install -D -m 644 -o 0 -g 0 "$KIT/ev_lux_map_config.xml" "$TREE/etc/ev_lux_map_config.xml"
label vendor_configs_file "$TREE/etc/ev_lux_map_config.xml"

save() {
    cat "$TREE/tmp" > "$TREE/$1"
    rm "$TREE/tmp"
}
drop_line() {
    grep -qE "$2" "$TREE/$1"
    grep -vE "$2" "$TREE/$1" > "$TREE/tmp"
    save "$1"
}
# a block is a paragraph between blank lines, e.g. a whole service definition
drop_block() {
    grep -qF "$2" "$TREE/$1"
    awk -v RS= -v ORS='\n\n' -v text="$2" 'index($0, text) == 0' "$TREE/$1" > "$TREE/tmp"
    save "$1"
}
replace() {
    grep -qF "$2" "$TREE/$1"
    F="$2" R="$3" awk '{ while ((i = index($0, ENVIRON["F"])) > 0) $0 = substr($0, 1, i - 1) ENVIRON["R"] substr($0, i + length(ENVIRON["F"])); print }' \
        "$TREE/$1" > "$TREE/tmp"
    save "$1"
}

# a12s speaker amp is SMA1303 (mute switch), A14 has AW88230 (profile + enable switch);
# the kernel has no ABOX OEM NXP Mode control
mp=etc/mixer_paths.xml
drop_line $mp '<ctl name="aw_dev_0_prof" value="0" />'
replace $mp '<ctl name="SPEAKER Switch" value="0" />' '<ctl name="Speaker Mute Switch(1:muted_0:un)" value="1" />'
replace $mp '<ctl name="SPEAKER Switch" value="1" />' '<ctl name="Speaker Mute Switch(1:muted_0:un)" value="0" />'
drop_line $mp '<ctl name="ABOX OEM NXP Mode" value="1" />'
if grep -qE 'aw_dev|SPEAKER Switch' "$TREE/$mp"; then echo "$mp: AW88230 controls left" >&2; exit 1; fi

# Lines that only log errors on a12s: no persist or spu partition, no vendor_dlkm, /data is not mounted
# at "on init", the vendor is read-only and some binaries are missing (32-bit, goodix, dhcpcd, wpal).
rc=etc/init/init.s5e3830.rc
drop_line $rc '^ *exec u:r:vendor_modprobe:s0 -- /vendor/bin/modprobe -a -d /vendor_dlkm/lib/modules input_booster_lkm\.ko$'
drop_line $rc '^ *# Set permissions for persist partition$'
drop_line $rc '^ *mkdir /persist '
drop_line $rc '^ *symlink /data/app /factory$'
drop_line $rc '^# Directory for GPS$'
drop_line $rc '^ *rm /data/system/gps/'
drop_line $rc '^ *setprop ro.radio.noril no$'
for s in goodixd dhcpcd_wlan0 iprenew_wlan0 dhcpcd_p2p iprenew_p2p dhcpcd_bt-pan iprenew_bt-pan; do
    drop_block $rc "service $s "
done

drop_line etc/init/init.sensorhub.rc ' /spu/sensorhub'
drop_line etc/init/wifi.rc ' /vendor/etc/wifi/indoorchannel\.info$'
drop_line etc/init/wifi_slsi_850.rc '^ *start wpal$'
drop_block etc/init/wifi_slsi_850.rc 'service wpal '
drop_block etc/init/snap_utility.rc 'service snap_utility_32 '
drop_block etc/init/snap_utility.rc 'start snap_utility_32'

# /sys entry without an attribute name
drop_line etc/ueventd.rc '^/sys/bus/iio/devices/iio:device\* +0664 +system +radio$'

replace build.prop 'ro.vendor.nfc.feature.chipname=SLSI' "$(grep -m1 '^ro.vendor.nfc.feature.chipname=' "$A12S/build.prop")"
# vendor_init may not set these; the stock file also repeats some lines with the same value
drop_line build.prop '^net\.dns[12]='
drop_line build.prop '^persist\.demo\.hdmirotationlock='
awk '!/=/ || !seen[$0]++' "$TREE/build.prop" > "$TREE/tmp"
save build.prop

rm -f "$OUT_IMG"
# stock A14 UUID so the same inputs give the same image hash
UUID=$(dump.erofs -s "$A14_IMG" | awk '/Filesystem UUID/ {print $NF}')
mkfs.erofs -zlz4hc,9 -T1230768000 -U "$UUID" -b4096 -Lvendor -E^xattr-name-filter --quiet "$OUT_IMG" "$TREE"
fsck.erofs "$OUT_IMG"
ls -l "$OUT_IMG"
sha1sum "$OUT_IMG"
