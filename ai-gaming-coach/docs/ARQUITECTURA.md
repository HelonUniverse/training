# AI Gaming Coach: arquitectura y restricciones de iOS (Milestone 1)

Este documento responde a la "Primera tarea" del brief: entorno, APIs de Apple verificadas, targets, sandboxing, comunicación, límites de la extensión, riesgos con Fortnite y plan concreto del Milestone 1.

---

## 1. Entorno inspeccionado

- El repositorio `training` no tenía ningún proyecto iOS; contiene cursos HTML y una app Expo (`desde-la-red/`). El proyecto nuevo vive aislado en `ai-gaming-coach/`.
- El entorno de desarrollo de esta sesión es **Linux, sin Xcode ni SDK de iOS**. Consecuencias:
  - El núcleo independiente de plataforma (`Packages/CoachKit`, módulo `CoachCore`) se compila y se prueba aquí con Swift 6.0 (Docker), con 20 tests.
  - El código que usa ReplayKit, AVFoundation, CoreImage y SwiftUI **no se puede compilar en Linux**. Se compila en CI con un runner macOS (`.github/workflows/ai-gaming-coach.yml`) y, en última instancia, hay que probarlo en un iPhone real. Ni el simulador ni CI pueden demostrar que llegan frames de Fortnite: eso solo se ve en un dispositivo.

## 2. APIs de Apple verificadas (documentación consultada el 26‑09‑2026)

| API | Disponible | Uso |
|---|---|---|
| `RPSystemBroadcastPickerView` (+ `preferredExtension`, `showsMicrophoneButton`) | iOS 12+ | Botón oficial que abre la hoja del sistema para iniciar el broadcast |
| `RPBroadcastSampleHandler` (`broadcastStarted/Paused/Resumed/Finished`, `processSampleBuffer(_:with:)`, `finishBroadcastWithError(_:)`) | iOS 10+ | Clase principal de la Broadcast Upload Extension |
| `RPSampleBufferType` (`.video`, `.audioApp`, `.audioMic`) | iOS 10+ | Separación de vídeo y audio |
| `RPVideoSampleOrientationKey` | iOS 11+ | Orientación del frame (Fortnite va en horizontal) |
| `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` | iOS 7+ | Contenedor compartido App Group |
| `CFNotificationCenterGetDarwinNotifyCenter` | iOS | Aviso entre procesos, sin payload |
| `AVAssetWriter` / `AVAssetWriterInput` (`transform`, `expectsMediaDataInRealTime`, `canApply(outputSettings:forMediaType:)`, `AVVideoScalingModeKey`, `AVVideoMaxKeyFrameIntervalDurationKey`) | iOS 4–7+ | Segmentos del buffer circular |
| `CIContext.jpegRepresentation(of:colorSpace:options:)`, `CIImage.oriented(_:)` | iOS 10/11+ | Keyframes JPEG |
| `os_proc_available_memory()` | iOS 13+ | Margen de memoria de la extensión, visible en Debug |
| `URLResourceValues.volumeAvailableCapacityForImportantUsage` | iOS 11+ | No arrancar si falta espacio |

Configuración de la extensión (Info.plist): `NSExtensionPointIdentifier = com.apple.broadcast-services-upload`, `RPBroadcastProcessMode = RPBroadcastProcessModeSampleBuffer`, y `NSExtensionPrincipalClass` apuntando a `SampleHandler`.

**No se usa ninguna API privada.** El botón *Start Coaching* es el propio `RPSystemBroadcastPickerView` superpuesto a nuestra etiqueta; no se recorren ni se manipulan sus subvistas internas.

### ⚠️ Hallazgo importante: ScreenCaptureKit llega a iOS 27

La documentación actual de Apple marca **ScreenCaptureKit como disponible en iOS 27** e indica literalmente: *"ScreenCaptureKit replaces ReplayKit for screen streaming and mirroring. A broadcast extension is no longer necessary."* El ejemplo oficial *Capturing screen content on iOS* usa `SCContentSharingPicker` para la captura de pantalla completa, y el modo de background `screen-capture` en `UIBackgroundModes` para que *"the stream survives backgrounding for full-display capture"*. También incluye `SCClipBufferingOutput`, un buffer circular del sistema (hasta 15 s en el ejemplo).

Qué significa para nosotros:

- **ReplayKit + Broadcast Upload Extension sigue siendo el camino correcto para el Milestone 1.** No está deprecado, funciona desde iOS 12 y es lo que pide el brief. iOS 27 acaba de salir y una base instalada solo con iOS 27 dejaría fuera a gran parte de los jugadores.
- Con ScreenCaptureKit en iOS 27, la captura correría **dentro del proceso de la app**, sin el límite de memoria de la extensión (ver §6). Para la visión on‑device (Core ML) del Milestone 2 eso puede ser decisivo.
- **No lo he verificado en dispositivo.** Tampoco sé cuánto tiempo mantiene iOS el stream mientras otra app (Fortnite) ocupa el primer plano, ni qué condiciones de App Review aplican al modo de background `screen-capture`. Antes de apostar por esa vía habría que prototiparla en un iPhone con iOS 27.
- La arquitectura ya lo permite: todo lo que no es "mover píxeles" está en `CaptureSessionController` (CoachCore). Una fuente `ScreenCaptureKitSource` en la app reutilizaría controlador, almacén, buffer, timeline y estadísticas sin cambios.

**Decisión pendiente para el propietario del producto:** ¿añadimos después del Milestone 1 una segunda fuente de captura con ScreenCaptureKit para iOS 27+, manteniendo ReplayKit para iOS 17–26?

## 3. Targets y carpetas

```
ai-gaming-coach/
├── project.yml                      XcodeGen → AIGamingCoach.xcodeproj
├── Packages/CoachKit/               Swift Package (solo Foundation; compila en Linux)
│   ├── Sources/CoachCore/
│   │   ├── Events/MatchEvent.swift          MatchEvent, tipos extensibles, formato 13:20.020
│   │   ├── State/GameState.swift            GameState, Estimate<T> (valor + confidence)
│   │   ├── Pipeline/CaptureSettings.swift   ajustes compartidos (buffer 30–300 s, privacidad…)
│   │   ├── Pipeline/FrameGate.swift         throttle de análisis + KeyframeScheduler
│   │   ├── Pipeline/SessionStatistics.swift contadores, drops por motivo, RateMeter
│   │   ├── Buffer/RollingSegmentBuffer.swift buffer circular por segmentos + preservación de clips
│   │   ├── Session/SessionManifest.swift    manifiesto (heartbeat), KeyframeRecord
│   │   ├── Session/SessionStore.swift       layout en disco, JSONL, borrado (privacidad)
│   │   ├── Session/CaptureSessionController.swift  orquestador independiente de la fuente
│   │   └── Contracts/Contracts.swift        GameAdapter, AIBackend, MockAIBackend, FightAnalysis
│   └── Tests/CoachCoreTests/                20 tests (pipeline simulado de extremo a extremo)
├── Shared/SharedEnvironment.swift   App Group, UserDefaults compartidos, Darwin notifications
├── BroadcastExtension/              target app-extension (com.apple.broadcast-services-upload)
│   ├── SampleHandler.swift          RPBroadcastSampleHandler
│   ├── BroadcastPipeline.swift      CMSampleBuffer → encoder / análisis / keyframes
│   ├── SegmentWriter.swift          AVAssetWriter rotativo (segmentos MP4 H.264 de 5 s)
│   └── KeyframeEncoder.swift        JPEG reducido + FrameProbe (luma, detección de negro)
└── App/                             target application (SwiftUI, iOS 17+)
    ├── AIGamingCoachApp.swift
    ├── Model/CoachModel.swift       lee el contenedor compartido, heartbeat, notificaciones
    └── Views/  Home, BroadcastPicker, SessionSummary, Debug (+ timeline), Settings, Sessions
```

Regla de dependencias: `App` y `BroadcastExtension` dependen de `CoachCore`, y `CoachCore` no depende de nada de Apple. La lógica de Fortnite irá en un `FortniteAdapter` que implemente `GameAdapter`, nunca dentro del motor.

## 4. Qué puede y qué no puede pasar entre la extensión y la app

Son **dos procesos distintos, cada uno con su sandbox**. La extensión la lanza iOS cuando el usuario inicia el broadcast; la app normalmente estará **suspendida** en background mientras el usuario juega.

| Puede compartirse | Mecanismo |
|---|---|
| Ficheros (vídeo, JPEG, JSON) | Contenedor App Group |
| Ajustes pequeños | `UserDefaults(suiteName: appGroup)` |
| "Algo ha cambiado" (sin datos) | Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) |
| Credenciales (futuro backend) | Keychain con access group compartido |

| No puede | Consecuencia |
|---|---|
| Pasar `CMSampleBuffer` / `CVPixelBuffer` a la app en vivo | Todo el procesamiento de frames ocurre **dentro de la extensión** |
| Despertar ni abrir la app desde la extensión | La app descubre las sesiones cuando vuelve a primer plano |
| Llamadas directas a objetos o memoria compartida | Solo ficheros y notificaciones |
| Payload en Darwin notifications | Solo sirven de aviso; los datos están en ficheros |
| Saber qué app está en primer plano | ReplayKit no lo dice (solo `broadcastAnnotated` si la app emisora lo anota). "Match detected" requiere visión (Milestone 2) |
| UI en la extensión (Upload) | Los errores se comunican con `finishBroadcastWithError`, que el sistema muestra al usuario |

## 5. Diseño de comunicación (implementado)

```
App Group container/Coach/Sessions/<uuid>/
  manifest.json     SessionManifest; reescrito de forma atómica ~1 vez/s = heartbeat
  events.jsonl      MatchEvent por línea (append-only) → Event Timeline
  keyframes.jsonl   índice de keyframes
  keyframes/*.jpg
  segments/*.mp4    buffer circular (se borra lo más antiguo)
  preserved/*.mp4   segmentos preservados alrededor de eventos (hard links)
```

- **Un escritor (la extensión) y varios lectores (la app).** El manifiesto se escribe en un fichero temporal y se renombra, así que la app nunca lee un JSON a medias. Los lectores de JSONL ignoran una última línea incompleta (hay un test que lo cubre).
- Cada escritura del manifiesto publica `com.aigamingcoach.session.updated`. Mientras está en primer plano, la app recarga solo la sesión viva. Como las Darwin notifications no se encolan, además hace polling cada segundo.
- La app considera la captura **conectada** si `updatedAt` tiene menos de 4 s. Es una señal real (la extensión está viva y escribiendo), no una suposición.
- Los ajustes (duración del buffer, FPS de análisis, *Don't Save Video*…) los escribe la app en los defaults del App Group, y la extensión toma una instantánea al empezar cada sesión.

## 6. Restricciones de la Broadcast Upload Extension

- **Memoria: es el límite crítico.** Apple no documenta una cifra en las páginas de ReplayKit. En la práctica, las Broadcast Upload Extensions tienen un límite de unos **50 MB**, y si lo superan el sistema las mata (jetsam) sin aviso. Por eso:
  - no se acumulan frames en RAM: el buffer circular son **ficheros de 5 s en disco**, codificados por hardware;
  - solo hay **1 frame en análisis** y **2 keyframes codificándose** a la vez como máximo; el resto se descarta y se contabiliza como drop, con su motivo;
  - `os_proc_available_memory()` se muestrea cada segundo, sale en Debug y se registra un evento `memoryPressure` por debajo de 12 MB.
  - Para el Milestone 2, Core ML dentro de la extensión tiene que caber en ese margen. Es uno de los motivos para evaluar ScreenCaptureKit en iOS 27 (§2).
- **Hilo de callbacks:** ReplayKit llama a los métodos del handler en serie. `processSampleBuffer` debe volver rápido: si retenemos buffers, su pool se agota y el sistema entrega menos frames. El análisis y los JPEG van en colas propias.
- **Fin de la sesión:** tras `broadcastFinished` el proceso puede terminar enseguida. Cerramos el último segmento con una espera acotada de 3 s y escribimos el manifiesto de forma síncrona.
- **CPU/GPU/térmica:** la extensión compite con Fortnite. Se limita el análisis a 10 FPS (configurable) y se reduce la resolución del vídeo (máx. 1280 px, 4 Mbps).
- **Red:** la extensión puede usar `URLSession` (para eso existen las Upload extensions), pero en el Milestone 1 no sube nada.
- **Audio:** `.audioApp` y `.audioMic` llegan por separado. En el Milestone 1 solo se cuentan; el micrófono está desactivado en el picker (`showsMicrophoneButton = false`).

## 7. Riesgos que pueden afectar a Fortnite durante la captura

1. **Rendimiento y temperatura.** Fortnite ya lleva la GPU y la CPU al límite. Codificar vídeo y analizar frames añade carga y puede provocar thermal throttling, bajadas de FPS en el juego o menos frames entregados. Mitigación: encoder por hardware, resolución reducida, análisis limitado. Hay que medirlo en dispositivo (FPS recibidos en Debug y la sensación en el juego).
2. **Contenido protegido.** Si una app o el sistema protege su contenido, ReplayKit entrega frames negros. No sé si Fortnite lo hace. `FrameProbe` cuenta los frames casi negros para detectarlo en la primera prueba en lugar de suponerlo.
3. **Interrupciones.** Bloquear el iPhone, algunas llamadas o el paso a pantallas del sistema pueden pausar o terminar el broadcast. Se gestionan `broadcastPaused/Resumed` y la sesión queda marcada.
4. **Jetsam de la extensión** (ver §6). Si ocurre, el manifiesto se queda en `running` sin heartbeat. La app muestra "Not connected" y la sesión conserva lo escrito hasta ese momento.
5. **Disponibilidad de Fortnite en iOS** según la región. Queda fuera de nuestro control; conviene confirmarla en los dispositivos de prueba.
6. **Selección del broadcast.** Si el usuario elige otro destino en la hoja del sistema, no recibimos nada. `preferredExtension` preselecciona el nuestro.
7. **Botón superpuesto.** Apple no garantiza que el botón interno de `RPSystemBroadcastPickerView` ocupe toda la vista. Si en el dispositivo solo responde el centro, la alternativa oficial es mostrar el glifo del sistema o iniciar el broadcast desde el Centro de Control (pulsación larga en *Grabar pantalla* → *AI Gaming Coach*).

Nada de lo implementado interactúa con Fortnite, lee su memoria ni automatiza controles. Solo observamos el vídeo que el usuario decide compartir desde la hoja del sistema.

## 8. Milestone 1: tareas y estado

| # | Criterio | Implementación | Estado |
|---|---|---|---|
| 1 | El proyecto compila | `project.yml` + CI macOS (`xcodebuild`, sin firma) | Pendiente del resultado de CI |
| 2 | La app funciona | `App/` (Home, Summary, Debug, Settings, Sessions) | Requiere dispositivo |
| 3 | La Broadcast Upload Extension funciona | `BroadcastExtension/` | Requiere dispositivo |
| 4–5 | Start Coaching → hoja oficial de iOS | `StartCoachingButton` / `BroadcastPicker` | Requiere dispositivo |
| 6–8 | Cambiar a Fortnite, recibir frames y demostrarlo | `BroadcastPipeline`, Debug en vivo (FPS, luma, frames negros) | Requiere dispositivo |
| 9 | Buffer circular básico | `SegmentWriter` + `RollingSegmentBuffer` | Lógica probada en Linux |
| 10 | Timestamps | tiempo de sesión desde el PTS del primer frame; timeline `mm:ss.SSS` | Probado |
| 11 | Keyframes periódicos | `KeyframeScheduler` + `KeyframeEncoder` | Lógica probada |
| 12 | Session Summary | duración, frames recibidos/procesados, keyframes, drops, FPS medio de procesamiento | Probado (datos); UI requiere dispositivo |

### Checklist para la primera prueba en iPhone

1. `brew install xcodegen && xcodegen generate` en `ai-gaming-coach/`, abrir el proyecto y poner tu `DEVELOPMENT_TEAM` en `project.yml`. Si hace falta, cambiar `BUNDLE_ID_PREFIX` y `APP_GROUP_IDENTIFIER` para que coincidan con tu cuenta.
2. Ejecutar en el iPhone y pulsar **Start Coaching**: debe aparecer la hoja del sistema con *AI Gaming Coach* preseleccionado. Pulsar *Start Broadcast*.
3. En Home deben aparecer "Screen capture: Connected" y el banner rojo de captura activa.
4. Abrir Fortnite y jugar 2–3 minutos. Observar si el juego pierde fluidez o se calienta más de lo normal.
5. Parar desde el indicador rojo o el Centro de Control y volver a la app. Debe aparecer el **Session Summary** automáticamente.
6. Comprobar en el summary o en Debug:
   - FPS recibidos (esperable: 30–60; ReplayKit solo envía frames cuando cambia la pantalla);
   - `nearBlackFrames` ≈ 0 (si no, hay protección de contenido);
   - memoria mínima disponible por encima de ~10 MB;
   - drops por motivo;
   - keyframes con imágenes de Fortnite en horizontal;
   - reproducir el buffer circular.
7. Activar *Don't Save Video* y repetir: al terminar no debe quedar ningún `.mp4`.

Solo con esa prueba superada se pasa al Milestone 2 (HUD, salud, escudo, inventario y slot seleccionado, con overlay de debug).
