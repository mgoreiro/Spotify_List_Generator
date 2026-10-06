# Spotify List Generator

App nativa de macOS (SwiftUI + SwiftData) que genera listas de 10, 20 o 50 canciones a partir de un
**artista** y un **tono** (tristes, alegres, románticas…), las crea en tu cuenta de Spotify y guarda
todo el histórico en una base de datos local.

## Funciones
- Listas de 10/20/50 canciones por artista + tono, con opción de incluir artistas similares.
- Selección por tono con la API gratuita de Google Gemini (modo automático: prueba primero los modelos *flash-lite*).
- Sin duplicados: agrupa Remastered / Remix / Live / Feat. y se queda con la mejor versión.
- Histórico persistente de peticiones y listas (SwiftData). Nada se borra salvo petición expresa.
- Regenerar una petición con otro tono o número de canciones.
- Tonos editables (añadir, quitar, restaurar por defecto).
- Exportar el histórico completo a JSON o CSV.
- Abrir/reproducir en la app de escritorio de Spotify.

## Requisitos
- macOS 14 o superior (Apple Silicon e Intel), Xcode / Swift 5.9+.
- Cuenta de Spotify. Las apps en *Development Mode* exigen que el propietario tenga Premium.
- (Opcional) clave gratuita de [Google AI Studio](https://aistudio.google.com/apikey). Sin ella, la lista contiene
  canciones del artista sin criterio de tono.

> Desde febrero de 2026 Spotify retiró para apps nuevas las categorías de Browse, las recomendaciones y audio
> features, por lo que los tonos no se descargan de Spotify: se guardan localmente y son editables.

## Puesta en marcha
1. En <https://developer.spotify.com/dashboard> crea una app (Web API) con el Redirect URI
   `http://127.0.0.1:8888/callback`.
2. Compila e instala en /Applications con `./Scripts/install.sh` (o `./Scripts/make_app.sh` para solo generar `build/SpotifyListGenerator.app`)
   (o `./Scripts/make_dmg.sh` para generar `build/SpotifyListGenerator.dmg`).
3. En Ajustes (⌘,) pega tu Client ID y pulsa **Conectar**; opcionalmente añade la clave de Gemini.

Los datos viven en `~/Library/Application Support/SpotifyListGenerator/history.store`.

## Distribución
El DMG se firma con tu certificado de *Apple Development* si existe (o ad-hoc). No está notarizado, así que en
otro Mac macOS pedirá confirmación: clic derecho → **Abrir**, o `xattr -dr com.apple.quarantine "/Applications/SpotifyListGenerator.app"`.
Para distribuirlo sin avisos hace falta un certificado *Developer ID* y notarizar.

## Licencia

MIT — ver [LICENSE](LICENSE).
