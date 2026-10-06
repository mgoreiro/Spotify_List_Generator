#!/bin/zsh
# Compila y empaqueta SpotifyListGenerator.app en ./build
set -e
cd "$(dirname "$0")/.."
# Binario universal (Apple Silicon + Intel)
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
APP=build/SpotifyListGenerator.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN/SpotifyListGenerator" "$APP/Contents/MacOS/"
# Icono: se genera por código y se convierte a .icns
mkdir -p "$APP/Contents/Resources" build/AppIcon.iconset
swift Scripts/make_icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Spotify List Generator</string>
<key>CFBundleIdentifier</key><string>com.miguel.SpotifyListGenerator</string>
<key>CFBundleExecutable</key><string>SpotifyListGenerator</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
# Firma estable (evita que el Llavero vuelva a pedir permiso tras cada build); ad-hoc si no hay certificado.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "OK → $APP ($(lipo -archs "$APP/Contents/MacOS/SpotifyListGenerator"))"
