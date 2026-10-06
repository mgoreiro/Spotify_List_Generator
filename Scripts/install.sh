#!/bin/zsh
# Compila, cierra la app si está abierta, la instala en /Applications y la abre.
set -e
cd "$(dirname "$0")/.."
./Scripts/make_app.sh
pkill -x SpotifyListGenerator 2>/dev/null && sleep 1 || true
rm -rf /Applications/SpotifyListGenerator.app
cp -R build/SpotifyListGenerator.app /Applications/
codesign --verify --deep --strict /Applications/SpotifyListGenerator.app
open /Applications/SpotifyListGenerator.app
echo "Instalada en /Applications/SpotifyListGenerator.app"
