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

## Compilar

```bash
# Núcleo (macOS o Linux)
cd Packages/CoachKit && swift test

# App + extensión (macOS con Xcode)
brew install xcodegen
xcodegen generate
open AIGamingCoach.xcodeproj   # poner DEVELOPMENT_TEAM en project.yml
```

El proyecto de Xcode, los Info.plist y los entitlements se generan desde `project.yml`, así que no están versionados. CI (`.github/workflows/ai-gaming-coach.yml`) ejecuta los tests del núcleo en Linux y compila la app y la extensión en macOS sin firmar.
