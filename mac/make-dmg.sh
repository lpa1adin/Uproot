#!/bin/zsh
# Собирает установщик build/Uproot-<версия>.dmg: окно с иконкой Uproot, стрелкой и папкой «Программы».
set -e
cd "$(dirname "$0")"

./build.sh
APP="build/Uproot.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="Uproot"
DMG="build/$NAME-$VERSION.dmg"
STAGE="build/dmg-stage"
RW="build/$NAME-rw.dmg"

rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"

# Образ с возможностью записи — чтобы расставить иконки
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
VOL="/Volumes/$NAME"
sleep 1

# Внешний вид окна: размер под фон 600×380, без панелей, крупные иконки на своих местах
if ! osascript <<OSA
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 800, 528}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "Uproot.app" of container window to {150, 200}
        set position of item "Программы" of container window to {450, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA
then
    echo "⚠️  Не удалось расставить иконки через Finder (нет разрешения?) — образ будет без оформления окна."
fi

rm -rf "$VOL/.fseventsd"   # служебная папка macOS, в установщике не нужна
chmod -Rf go-w "$VOL" 2>/dev/null || true
sync
hdiutil detach -quiet "$DEVICE"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$RW" "$STAGE"
echo "Установщик: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
