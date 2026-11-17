#!/bin/bash
# BugOS - NOTIFICATION_FIX A17 - SystemUI
#
# VẤN ĐỀ: thông báo tới nhưng KHÔNG sáng màn hình và KHÔNG có chuông. Chỉ một
# vài app (WeChat, Messenger...) mới kêu và đánh thức được.
#
# NGUYÊN NHÂN GỐC: bản ROM Trung Quốc bật chế độ "whitelist" cho thông báo.
#   NotificationSettingsManager.<clinit> tính:
#       USE_WHITE_LISTS = !IS_INTERNATIONAL_BUILD
#   Trên ROM CN, IS_INTERNATIONAL_BUILD = false -> USE_WHITE_LISTS = TRUE.
#   Khi cờ này bật, cả ba hàm quyết định trải nghiệm đều chỉ trả TRUE nếu app
#   nằm trong mảng whitelist của SystemUI:
#       canSound(ctx, pkg, channel)          -> có chuông?
#       canVibrate(ctx, pkg, channel)        -> có rung?
#       canShowOnKeyguard(ctx, pkg, channel) -> hiện trên màn hình khoá?
#   App không có tên trong whitelist -> canSound=false, canVibrate=false,
#   canShowOnKeyguard=false. Hệ quả kéo theo:
#       * AlertCoordinator.buzzBeepBlink tính buzz/beep = 0 -> im lặng.
#       * MiuiAlertManager không gọi wakeUpForNotificationInternal() vì
#         chuỗi gate "f,!show on keyguard" return sớm -> màn hình không sáng.
#
# CÁCH VÁ: ép USE_WHITE_LISTS = false. Khi đó MIUI chuyển sang chế độ
#   "blocklist": app được phép mặc định, chỉ chặn nếu tên nằm trong
#   mBlockFloatPackages. Đây đúng là hành vi của bản quốc tế, không phải nới
#   lỏng tuỳ tiện: mọi giới hạn người dùng đã đặt (tắt chuông từng app,
#   DND, mức importance của channel) vẫn còn nguyên tác dụng.
#
# PHƯƠNG PHÁP: patch trực tiếp classes*.dex bằng baksmali/smali, đóng gói lại
#   bằng bin/tools/apk_dex_patch.py - chỉ thay dex, giữ nguyên resources.arsc,
#   AndroidManifest.xml, res/, META-INF của APK gốc.
#
# HAI CÁI BẪY ĐÃ LÀM HỎNG BẢN BUILD TRƯỚC (annibale, OS4.0.6, A17):
#   1. Script cũ xoá dex TRƯỚC khi kiểm tra class mục tiêu:
#          rm -f "$dex"                    # xoá
#          TARGET=$(find "$dexout" ...)    # không thấy class
#          continue                        # -> dex biến mất, không ghi lại
#      Kết quả: APK chỉ còn classes3.dex, mất classes.dex + classes2.dex
#      (META-INF/MANIFEST.MF của bản gốc vẫn khai báo đủ 3 dex - bằng chứng).
#   2. Repack bằng `zip -r -X` nén lại resources.arsc. Từ Android 11,
#      PackageManager từ chối scan thư mục priv-app:
#          "Targeting R+ (version 30 and above) requires the resources.arsc of
#           installed APKs to be stored uncompressed and aligned on a 4-byte
#           boundary"
#      -> package com.android.systemui KHÔNG được đăng ký -> mất status bar,
#         mất nav bar, launcher báo "systemui proxy isn't ready", RescueParty
#         reboot liên tục.
#   Bản này KHÔNG tự đóng zip: dùng apk_dex_patch.py (dex + resources.arsc
#   luôn STORED và canh 4 byte) rồi verify lại trước khi thay APK.

work_dir=$(pwd)
[ -f "$work_dir/functions.sh" ] && source "$work_dir/functions.sh"

MAIN_FOLDER="$work_dir/build/baserom/images"
TOOLS_DIR="$work_dir/bin/apktool"
BAK="$TOOLS_DIR/baksmaliv2.jar"
SMA="$TOOLS_DIR/smaliv2.jar"
DEXTOOL="$work_dir/bin/tools/apk_dex_patch.py"
FINDER="$work_dir/bin/modfile/UpdateFile/Apps_Replace/find_apk_by_package.py"
PKG="com.android.systemui"

log_msg() {
    if type mods &>/dev/null; then mods "$1"
    elif type patch &>/dev/null; then patch "$1"
    else echo "[SystemUI] $1"; fi
}

warn_msg() {
    if type warn &>/dev/null; then warn "$1"; else echo "[SystemUI][WARN] $1"; fi
}

ENABLE=$(grep -m1 '^systemui_notification_fix=' "$work_dir/config.env" 2>/dev/null | cut -d= -f2 | tr -d ' \r\n')
[ -z "$ENABLE" ] && ENABLE=true
if [ "$ENABLE" != "true" ]; then
    log_msg "SystemUI: bỏ qua (systemui_notification_fix != true)"
    exit 0
fi

[ -f "$DEXTOOL" ] || { warn_msg "SystemUI: thiếu bin/tools/apk_dex_patch.py - bỏ qua"; exit 0; }

APK=$(find "$MAIN_FOLDER" -type f -name "MiuiSystemUI.apk" 2>/dev/null | head -n1)
if [ -z "$APK" ]; then
    warn_msg "SystemUI: ROM không có MiuiSystemUI.apk - bỏ qua"
    exit 0
fi

sdkLevel=$(cat "$work_dir/bin/ddevice/sdkLevel.txt" 2>/dev/null | tr -d '\r\n ')
[ -z "$sdkLevel" ] && sdkLevel=37

TMP="$work_dir/systemui_patch"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
rm -rf "$TMP"
mkdir -p "$TMP"

log_msg "SystemUI: tách dex từ $(basename "$APK")…"
DEXLIST=$(python3 "$DEXTOOL" unpack "$APK" "$TMP" 2>/dev/null)
if [ -z "$DEXLIST" ]; then
    warn_msg "SystemUI: không tách được classes*.dex - giữ nguyên APK gốc"
    exit 0
fi
NDEX=$(printf '%s\n' "$DEXLIST" | grep -c '^classes')

for d in "$TMP"/dex/*.dex; do
    [ -f "$d" ] || continue
    n=$(basename "$d" .dex)
    if ! java -jar "$BAK" d --api "$sdkLevel" "$d" -o "$TMP/smali/$n" >/dev/null 2>&1; then
        warn_msg "SystemUI: baksmali $n thất bại - giữ nguyên APK gốc"
        exit 0
    fi
done

TARGET=$(find "$TMP/smali" -type f -name "NotificationSettingsManager.smali" 2>/dev/null | head -n1)
if [ -z "$TARGET" ]; then
    warn_msg "SystemUI: không thấy NotificationSettingsManager.smali - giữ nguyên APK gốc"
    exit 0
fi

if ! python3 - "$TARGET" <<'PYEOF'
import io, re, sys

path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()

pat = re.compile(
    r'^([ \t]*)sput-boolean\s+(\w+),\s*Lcom/miui/systemui/notification/NotificationSettingsManager;->USE_WHITE_LISTS:Z',
    re.M)

def repl(m):
    indent = m.group(1)
    reg = m.group(2)
    return (f'{indent}const/4 {reg}, 0x0\n\n'
            f'{indent}sput-boolean {reg}, Lcom/miui/systemui/notification/NotificationSettingsManager;->USE_WHITE_LISTS:Z')

src2, n = pat.subn(repl, src, count=1)
if n == 0:
    sys.exit(2)

io.open(path, 'w', encoding='utf-8', newline='\n').write(src2)
print('patched')
PYEOF
then
    warn_msg "SystemUI: không khớp mẫu USE_WHITE_LISTS - giữ nguyên APK gốc"
    exit 0
fi

# Ghi lại TẤT CẢ dex đã tách, kể cả dex không chứa class mục tiêu.
for d in "$TMP"/smali/*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    if ! java -jar "$SMA" a --api "$sdkLevel" "$d" -o "$TMP/dex/$n.dex" >/dev/null 2>&1; then
        warn_msg "SystemUI: smali $n thất bại - giữ nguyên APK gốc"
        exit 0
    fi
done

OUT="$TMP/MiuiSystemUI.apk"
if ! python3 "$DEXTOOL" repack "$APK" "$TMP" "$OUT" >/dev/null 2>&1; then
    warn_msg "SystemUI: đóng gói lại thất bại - giữ nguyên APK gốc"
    exit 0
fi

if ! unzip -t "$OUT" >/dev/null 2>&1; then
    warn_msg "SystemUI: APK mới hỏng (zip) - giữ nguyên bản gốc"
    exit 0
fi

# Chốt chặn cuối: đúng số dex, resources.arsc STORED + canh 4 byte.
# Sai một trong hai là PackageManager bỏ luôn package -> mất SystemUI.
if ! python3 - "$OUT" "$NDEX" <<'PYEOF'
import sys, zipfile

out, ndex = sys.argv[1], int(sys.argv[2])
z = zipfile.ZipFile(out)
bad = []
dex = 0
for i in z.infolist():
    if i.filename.startswith('classes') and i.filename.endswith('.dex'):
        dex += 1
    if i.filename in ('resources.arsc', 'AndroidManifest.xml'):
        off = i.header_offset + 30 + len(i.filename.encode('utf-8')) + len(i.extra)
        if i.compress_type != zipfile.ZIP_STORED:
            bad.append('%s bi nen (method=%d)' % (i.filename, i.compress_type))
        elif off % 4:
            bad.append('%s lech canh le (off=%d)' % (i.filename, off))
if dex != ndex:
    bad.append('so dex %d != %d' % (dex, ndex))
if bad:
    print('; '.join(bad), file=sys.stderr)
    sys.exit(1)
PYEOF
then
    warn_msg "SystemUI: APK mới không đạt yêu cầu (arsc STORED/canh 4 hoặc thiếu dex) - giữ nguyên bản gốc"
    exit 0
fi

if [ -f "$FINDER" ]; then
    got=$(python3 "$FINDER" x --pkg-of "$OUT" 2>/dev/null)
    if [ "$got" != "$PKG" ]; then
        warn_msg "SystemUI: APK mới sai package ($got) - giữ nguyên bản gốc"
        exit 0
    fi
fi

APKDIR=$(dirname "$APK")
# KHÔNG xoá $APKDIR/oat: ART so checksum dex trong vdex/odex với APK và tự
# biên dịch lại khi lệch. Xoá đi thì lần boot đầu phải chạy bằng interpreter -
# với app sống-còn như SystemUI thì đó là rủi ro không cần thiết.
cp -f "$OUT" "$APK"

log_msg "SystemUI: da va USE_WHITE_LISTS -> false ($NDEX dex, arsc STORED) - thong bao se sang man hinh + co chuong"
exit 0
