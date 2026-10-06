#!/bin/zsh
# Genera build/SpotifyListGenerator.dmg (app + acceso directo a /Applications).
set -e
cd "$(dirname "$0")/.."
./Scripts/make_app.sh
VOL="Spotify List Generator"
STAGE=build/dmg
rm -rf "$STAGE" build/SpotifyListGenerator.dmg
mkdir -p "$STAGE"
cp -R build/SpotifyListGenerator.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO build/SpotifyListGenerator.dmg >/dev/null
rm -rf "$STAGE"
echo "OK → build/SpotifyListGenerator.dmg ($(du -h build/SpotifyListGenerator.dmg | cut -f1))"
