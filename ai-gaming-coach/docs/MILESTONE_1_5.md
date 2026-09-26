# Milestone 1.5: proveedor de captura ScreenCaptureKit (prototipo, iOS 27+)

**Estado:** implementado y compilado contra el SDK de iOS 27 en CI (ver §8). **No se ha probado en dispositivo.** Nada de este documento afirma que la captura funcione con Fortnite en primer plano: eso lo decide la prueba física de §6.

Milestone 2 (visión de Fortnite) sigue bloqueado hasta cerrar la **decision gate** de §7.

---

## 1. Arquitectura de captura

```
                 ┌──────────────────────────────┐     ┌──────────────────────────────────┐
 iOS 17+         │ ReplayKitCaptureProvider     │     │ ScreenCaptureKitCaptureProvider  │  iOS 27+
 (compatib.)     │ = Broadcast Upload Extension │     │ (en la app, SCStream)            │  (experimental)
                 │ proceso aparte, límite ~50MB │     │ SCContentSharingPicker           │
                 └──────────────┬───────────────┘     └───────────────┬──────────────────┘
                                │ CMSampleBuffer                      │ GameplayFrame<CMSampleBuffer>
                                ▼                                     ▼
                 BroadcastPipeline (M1, sin cambios)          CaptureSessionRunner (CoachCore)
                                │                                     │
                                │                                     ▼
                                │                               FramePipeline (Shared)
                                └───────────────┬─────────────────────┘
                                                ▼
         SegmentWriter · KeyframeEncoder · FrameProbe  (mismos componentes en ambos caminos)
                                                ▼
         CaptureSessionController (CoachCore): reloj de sesión, FrameGate, RollingSegmentBuffer,
         keyframes, Event Timeline, estadísticas, SessionStore → Session Summary / Debug / A/B
```

- **`GameplayCaptureProvider`** (CoachCore): `start() async throws`, `stop() async`, `frames: AsyncStream<GameplayFrame<Payload>>` y `statuses: AsyncStream<CaptureProviderStatus>`. `Payload` es el contenedor nativo (`CMSampleBuffer`), que pasa sin conversiones.
- **`GameplayFrame`**: `sequenceNumber`, `timestamp` (PTS en el reloj del host), `width`, `height`, `orientation` (EXIF), `source` y `payload`.
- **El buffer circular no pertenece a ningún proveedor.** `RollingSegmentBuffer` y su contabilidad viven en `CaptureSessionController` (CoachCore); `SegmentWriter` solo codifica. Con ReplayKit, los segmentos se escriben desde la extensión por la frontera de procesos, pero el concepto y la política son los mismos.
- **Rendimiento:** los píxeles se quedan en el `CVPixelBuffer` del proveedor. El análisis lee el plano de luma directamente, el vídeo va al encoder por hardware y solo los keyframes (1 cada 5 s por defecto) se convierten a JPEG. No hay `UIImage` ni decodificaciones intermedias.
- **ReplayKit no se ha tocado.** `BroadcastPipeline` seguirá como está hasta pasar la prueba física del Milestone 1. Después, su `handleVideo` se sustituirá por `FramePipeline.process(GameplayFrame)`: es la misma lógica, que ya está duplicada a propósito en `FramePipeline`.

## 2. APIs verificadas (documentación de Apple, septiembre de 2026)

| API | iOS | Uso |
|---|---|---|
| `SCContentSharingPicker.shared`, `isActive`, `isAvailable`, `defaultConfiguration`, `add(_:)`, `remove(_:)`, `present()` | 27.0 | Selector oficial; `present()` = pantalla completa |
| `SCContentSharingPickerConfiguration` (`showsMicrophoneControl`, `showsCameraControl`) | 27.0 | Micro y cámara ocultos |
| `SCContentSharingPickerObserver` (`didUpdateWith:for:`, `didCancelFor:`, `contentSharingPickerStartDidFailWithError`) | 27.0 | Consentimiento, cancelación y error |
| `SCStream(filter:configuration:delegate:)`, `addStreamOutput(_:type:sampleHandlerQueue:)`, `startCapture()`, `stopCapture()` | 27.0 | Stream |
| `SCStreamConfiguration` (`width`, `height`, `capturesAudio`) | 27.0 | Solo `capturesAudio = false`; el resto queda por defecto |
| `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)`, `SCStreamOutputType.screen` | 27.0 | Frames |
| `SCStreamDelegate.stream(_:didStopWithError:)`, `streamDidBecomeActive/Inactive` | 27.0 | Paradas e interrupciones |
| `SCStreamFrameInfo.status`, `.videoOrientation`; `SCFrameStatus` | 27.0 | Solo se procesan los frames `complete`; orientación EXIF |
| `SCStreamError.Code` (`userStopped`, `systemStoppedStream`, `missingBackgroundMode`, `userDeclined`, `notSupported`…) | 27.0 | Motivo de parada |
| `UIBackgroundModes` = `screen-capture` | documentado para iOS/iPadOS | Captura con la app en background |

**No disponibles en iOS** (solo macOS): `minimumFrameInterval`, `pixelFormat`, `queueDepth`, `scalesToFit`, `preservesAspectRatio`, `captureResolution`, `allowedPickerModes` y `updateContentFilter`. Por eso no podemos fijar los FPS ni el formato de píxel del stream. El análisis se limita después, con `FrameGate`, y `FrameProbe` acepta tanto 420 como BGRA.

## 3. Ejecución en background: qué se necesita

| Elemento | Valor | Fuente |
|---|---|---|
| Capability | *Background Modes* → **Screen Capture** | "Configuring background execution modes": `screen-capture` — *"The app captures and streams screen content while in the background"* (iOS, iPadOS) |
| Info.plist | `UIBackgroundModes: [screen-capture]` | Generado desde `project.yml`. Las versiones anteriores de iOS ignoran el valor |
| Info.plist | `NSScreenCaptureUsageDescription` | Lo pide la página general de ScreenCaptureKit. Su página de referencia devuelve 404, así que lo tratamos como obligatorio pero sin más detalle documentado |
| Entitlements | **Ninguno nuevo** (solo el App Group que ya existía) | `com.apple.developer.persistent-content-capture` es exclusivo de macOS/VNC y **no** se usa |
| Modo `audio` | **No añadido** | El ejemplo de Apple lo usa solo para que el *micrófono* siga grabando. Nosotros no capturamos audio. Si en el dispositivo la captura se detiene sin él, se documentará como hallazgo; no se añadirá "por si acaso" |

Si falta el modo de background, ScreenCaptureKit devuelve `SCStreamError.Code.missingBackgroundMode`. La sesión queda como `failed: missingBackgroundMode` y el motivo aparece en el Session Summary.

## 4. Flujo de consentimiento y UI del sistema

1. En iOS 27, Home muestra **Capture provider: ScreenCaptureKit / ReplayKit**. ScreenCaptureKit aparece marcado como *Experimental · preferred test*. La elección se recuerda y se puede cambiar cuando no hay captura en curso. En iOS < 27 solo existe ReplayKit.
2. **Start Coaching** → la app llama a `present()` y el sistema muestra el selector de Apple. La app no captura nada hasta que el usuario confirma allí. Si lo cierra, no se crea ninguna sesión (hay un test que lo cubre).
3. Con la captura activa, iOS muestra su propio indicador. La app muestra además el banner rojo *Screen capture is active* y un botón **Stop Coaching**.
4. El usuario cambia a Fortnite. La app pasa a background y la captura sigue, siempre que el modo `screen-capture` funcione como está documentado. **Esto es lo que hay que verificar** (§6).

### Qué ocurre si…

| Situación | Comportamiento implementado | Registro |
|---|---|---|
| El usuario para desde la UI del sistema (indicador o Centro de Control) | `didStopWithError(userStopped)` → `stopped(userSystemUI)` → se cierra el segmento y la sesión | Sesión `finished`; evento `captureSourceStatus: stopped: userSystemUI` |
| El usuario para desde la app | `stopCapture()` → `stopped(userInApp)` | Sesión `finished` |
| El sistema detiene el stream | `systemStoppedStream` → `stopped(system)` | Sesión `failed` con el motivo |
| Falta el modo de background u otro error | `failed(<código>)` | Sesión `failed: missingBackgroundMode (…)` |
| El contenido compartido desaparece | `streamDidBecomeInactive` → `interrupted` | Evento en la timeline; si vuelve, `running` |
| **Fortnite pasa a ser contenido protegido o no disponible** | ScreenCaptureKit entrega frames sin imagen (`blank`, `suspended`…) o imágenes negras. Los primeros se cuentan por estado y **no** cuentan como frames recibidos; las imágenes negras se detectan con `FrameProbe` | *Frames without image* en Debug/Summary; *% de frames negros* en el informe. Con Fortnite en primer plano, cualquiera de las dos cifras alta significa que el enfoque no sirve |
| El pipeline va más lento que la entrada | El buffer de hand-off (1 frame) sustituye el frame antiguo | Drop `pipelineBackpressure` |

## 5. Memoria, CPU, térmica y latencia

Se mide lo mismo que con ReplayKit y a través del mismo código: `ProcessMetrics` (en CoachCore) muestrea cada segundo la huella física, la CPU y el estado térmico, y `CaptureSessionController` registra la latencia desde el PTS hasta el procesamiento. Con ScreenCaptureKit el proceso medido es la propia app, incluida su UI. Con ReplayKit, es la extensión. **No se da por hecho que la memoria sea ilimitada:** el buffer circular sigue acotado (90 s configurables, en segmentos de 5 s en disco) y se registran el pico de disco y el de memoria.

No se optimiza la resolución hasta medir. `SCStreamConfiguration` se deja con los valores por defecto y la resolución real queda registrada en el informe.

## 6. Prueba física del prototipo (después de la de ReplayKit)

Mismo procedimiento que en [`DEVICE_TEST.md`](DEVICE_TEST.md), pero en un iPhone con **iOS 27** y **ScreenCaptureKit** seleccionado. El paso A cambia: Start Coaching → selector de Apple → compartir la pantalla completa.

**Condición de parada, tal como la pediste:** si con Fortnite en primer plano no llegan frames (el contador no sube durante el paso C), la sesión falla con `missingBackgroundMode` / `notSupported`, o casi todos los frames son `blank` o negros, **el prototipo se detiene**. Se documenta el resultado y ReplayKit sigue siendo el único proveedor.

## 7. Decision gate

Después de las dos pruebas físicas, se abre **Debug → ReplayKit vs ScreenCaptureKit** (solo en builds DEBUG) y se pulsa **Copy CAPTURE PROVIDER COMPARISON**. Esa página solo agrega sesiones reales completadas con frames. Si un proveedor no tiene ninguna, dice *"no completed device session recorded"* y no muestra cifras.

Con esos datos se completa:

```
CAPTURE PROVIDER COMPARISON

ReplayKit:        compatibility · stability · FPS · latency · memory · Fortnite impact · limitations
ScreenCaptureKit: compatibility · stability · FPS · latency · memory · Fortnite impact · limitations

PRIMARY iOS 27+ provider: …
LEGACY provider: …
```

Lo que ya se sabe sin medir (compatibilidad y límites documentados):

- **ReplayKit:** iOS 12+ (la app pide iOS 17+). Corre en un proceso aparte con un límite de memoria estricto (unos 50 MB, no documentado oficialmente). Los frames no llegan a la app en vivo. No está deprecado.
- **ScreenCaptureKit:** solo iOS 27+. Captura dentro de la app, así que no tiene el límite de la extensión, pero depende del modo `screen-capture`. Desde la app no se puede fijar ni el frame rate ni el formato de píxel. Según Apple, *"replaces ReplayKit for screen streaming and mirroring"*.

La recomendación final **no se emitirá hasta tener datos de ambos**.

## 8. Compilación

- **Xcode 16 / SDK de iOS 18** (job `ios-build`): el SDK no incluye ScreenCaptureKit para iOS, así que el proveedor se excluye con `#if canImport(ScreenCaptureKit)` y la app funciona solo con ReplayKit.
- **Xcode 27 / SDK de iOS 27** (job `ios-build-sdk27`, imagen preview `xcode-27` de GitHub): compila el proveedor contra las cabeceras reales de Apple y comprueba que el símbolo `ScreenCaptureKitCaptureProvider` está en el binario y que `UIBackgroundModes` incluye `screen-capture`. Primer resultado (26‑09‑2026, Xcode 27.2, SDK iphoneos27.2): **BUILD SUCCEEDED, 0 warnings en el código del proyecto**.
- Ambos jobs fallan si aparece cualquier warning en el código del proyecto.
