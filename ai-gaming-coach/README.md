# AI Gaming Coach (iOS MVP)

Coach de juego con IA para iPhone. Primer juego: Fortnite Zero Build. La app observa **solo** el vídeo que el usuario comparte desde la hoja oficial de broadcast de iOS (ReplayKit + Broadcast Upload Extension). No interactúa con el juego ni lee su memoria.

- Arquitectura, APIs verificadas, límites de iOS y riesgos: [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md)
- Estado: **Milestone 1** (captura → frame → buffer → keyframes → timeline → Session Summary).

## Capas

```
CAPTURE (ReplayKit extension)  →  STREAM PROCESSING (BroadcastPipeline)
  →  GAME VISION (GameAdapter, M2)  →  EVENT ENGINE (M3)  →  MATCH MEMORY (SessionStore)
  →  AI REASONING (AIBackend, M4)  →  COACHING (M4–5)  →  PLAYER MODEL (M5)
```

`CoachCore` (Swift Package) solo depende de Foundation. Contiene el controlador de sesión, el buffer circular, la timeline, las estadísticas y el almacenamiento, y se puede reutilizar con otras fuentes de captura (Android, PC, consolas).

## Instalar en un iPhone

Sigue [`INSTALL_ON_IPHONE.md`](INSTALL_ON_IPHONE.md). Solo necesitas Xcode: el proyecto `AIGamingCoach.xcodeproj` ya está generado y versionado.

## Desarrollo

```bash
# Núcleo (macOS o Linux)
cd Packages/CoachKit && swift test

# Tras editar project.yml, regenera y versiona el proyecto:
brew install xcodegen && xcodegen generate
```

CI (`.github/workflows/ai-gaming-coach.yml`) ejecuta los tests del núcleo y compila el proyecto versionado, sin firma, con Xcode 16, 26 y 27. Falla si el proyecto deja de coincidir con `project.yml` o si aparece algún warning.
