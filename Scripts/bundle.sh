#!/bin/bash
# Builds Cyclop.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Cyclop.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Cyclop"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cyclop"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Cyclop</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleDisplayName</key><string>Cyclop</string>
    <key>CFBundleIdentifier</key><string>com.cyclop.app</string>
    <key>CFBundleExecutable</key><string>Cyclop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Таблицы строк кладутся прямо в бандл, а не через ресурсы SwiftPM: бандл здесь
# собирается вручную, и .lproj рядом с исполняемым файлом — то, где их ищет сама
# macOS. Язык она выбирает потом сама, по списку предпочитаемых у пользователя.
echo "==> локализации"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    echo "    $(basename "$lproj")"
done

# Подпись стабильной identity, если она есть. Это не косметика: macOS привязывает
# выданные разрешения к подписи, а ad-hoc подпись меняется с каждой сборкой —
# Универсальный доступ, нужный блокировке клавиатуры, приходилось бы выдавать
# заново после каждой пересборки. Берётся первая доступная codesigning identity;
# переопределяется через CYCLOP_SIGN_IDENTITY. Без identity остаётся ad-hoc —
# приложение работает, просто разрешения живут одну сборку.
IDENTITY="${CYCLOP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[0-9A-F]*[[:space:]]*"\(.*\)"$/\1/p' | head -1)}"

if [ -n "$IDENTITY" ]; then
    echo "==> signing as $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || \
        echo "    (codesign failed — the app still runs, but TCC prompts may repeat)"
else
    echo "==> ad-hoc signing"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
        echo "    (codesign failed — the app still runs, but TCC prompts may repeat)"
fi

echo "==> done: $APP"
