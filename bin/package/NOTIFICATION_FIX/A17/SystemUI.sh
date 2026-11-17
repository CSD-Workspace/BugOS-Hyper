#!/bin/bash
# BugOS - NOTIFICATION_FIX A17 - SystemUI
#
# VẤN ĐỀ (đã kiểm chứng trên máy annibale, OS4.0.6 / Android 17):
#   - Thông báo tới nhưng KHÔNG sáng màn hình và KHÔNG có chuông.
#   - Chỉ một vài app (WeChat...) mới kêu và đánh thức được.
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
# PHƯƠNG PHÁP: patch trực tiếp classes.dex bằng baksmali/smali (không rebuild
# toàn bộ APK bằng APKEditor -> tránh hỏng cấu trúc APK gây SystemUI crash
# / Rescue Party / bootloop). Chỉ thay file classes.dex, giữ nguyên
# resources, manifest, META-INF của APK gốc.

work_dir=$(pwd)
[ -f "$work_dir/functions.sh" ] && source "$work_dir/functions.sh"

MAIN_FOLDER="$work_dir/build/baserom/images"
TOOLS_DIR="$work_dir/bin/apktool"
BAK="$TOOLS_DIR/baksmaliv2.jar"
SMA="$TOOLS_DIR/smaliv2.jar"

log_msg() {
    if type mods &>/dev/null; then mods "$1"
    elif type patch &>/dev/null; then patch "$1"
    else echo "[SystemUI] $1"; fi
}

warn_msg() {
    if type warn &>/dev/null; then warn "$1"; else echo "[SystemUI][WARN] $1"; fi
}

APK=$(find "$MAIN_FOLDER" -type f -name "MiuiSystemUI.apk" 2>/dev/null | head -n1)
if [ -z "$APK" ]; then
    warn_msg "SystemUI: ROM không có MiuiSystemUI.apk - bỏ qua"
    exit 0
fi

sdkLevel=$(cat "$work_dir/bin/ddevice/sdkLevel.txt" 2>/dev/null || echo "37")

DEC="$work_dir/systemui_dex"
rm -rf "$DEC"
mkdir -p "$DEC"

log_msg "SystemUI: trích xuất classes.dex từ $(basename "$APK")…"
unzip -o "$APK" -d "$DEC" >/dev/null 2>&1

DEX_FILES=$(find "$DEC" -maxdepth 1 -name "classes*.dex" 2>/dev/null | sort)
if [ -z "$DEX_FILES" ]; then
    warn_msg "SystemUI: không thấy classes.dex - bỏ qua"
    rm -rf "$DEC"
    exit 0
fi

patched=0
for dex in $DEX_FILES; do
    dexout="${dex}.out"
    if ! java -jar "$BAK" d --api "$sdkLevel" "$dex" -o "$dexout" >/dev/null 2>&1; then
        warn_msg "SystemUI: baksmali thất bại cho $dex - giữ APK gốc"
        rm -rf "$DEC"
        exit 0
    fi
    rm -f "$dex"

    TARGET=$(find "$dexout" -type f -name "NotificationSettingsManager.smali" 2>/dev/null | head -n1)
    if [ -z "$TARGET" ]; then
        rm -rf "$dexout"
        continue
    fi

    python3 - "$TARGET" <<'PY'
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
print("patched")
PY

    if [ $? -ne 0 ]; then
        warn_msg "SystemUI: vá smali thất bại cho $dex - giữ APK gốc"
        rm -rf "$DEC"
        exit 0
    fi

    if ! java -jar "$SMA" a --api "$sdkLevel" "$dexout" -o "$dex" >/dev/null 2>&1; then
        warn_msg "SystemUI: smali reassemble thất bại cho $dex - giữ APK gốc"
        rm -rf "$DEC"
        exit 0
    fi
    rm -rf "$dexout"
    patched=1
done

if [ "$patched" -eq 0 ]; then
    warn_msg "SystemUI: không tìm thấy NotificationSettingsManager.smali trong bất kỳ dex nào - bỏ qua"
    rm -rf "$DEC"
    exit 0
fi

# Repack APK: giữ tất cả file gốc, chỉ thay thế classes.dex đã patch.
OUT="$work_dir/MiuiSystemUI_patched.apk"
rm -f "$OUT"
cd "$DEC"
zip -r -X "$OUT" . >/dev/null 2>&1
cd "$work_dir"

if [ ! -s "$OUT" ]; then
    warn_msg "SystemUI: APK ra rỗng - giữ APK gốc"
    rm -rf "$DEC"
    exit 0
fi

if which zipalign >/dev/null 2>&1; then
    zipalign 4 "$OUT" "$APK" 2>/dev/null || cp -f "$OUT" "$APK"
else
    cp -f "$OUT" "$APK"
fi

log_msg "SystemUI: da va USE_WHITE_LISTS -> false trong classes.dex (patch classes.dex khong rebuild toan bo APK)"

rm -rf "$DEC"
rm -f "$OUT"
exit 0
