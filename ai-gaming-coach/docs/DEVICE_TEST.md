# Prueba en dispositivo físico — Milestone 1 (ReplayKit)

Objetivo: comprobar en un iPhone real que la Broadcast Upload Extension recibe y procesa gameplay de Fortnite, y dejar cada prueba registrada en un bloque **DEVICE TEST RESULT** comparable. Ni el simulador ni CI pueden demostrar esto.

Esta prueba se hace con la implementación ReplayKit del Milestone 1 **sin modificar**. La instrumentación que alimenta el informe (memoria, CPU, estado térmico, latencia, disco) vive en `CoachCore`, y la extensión la ejecuta automáticamente sin que haya cambiado su código.

## Preparación

1. En `ai-gaming-coach/`: `brew install xcodegen && xcodegen generate`. En `project.yml`, pon `DEVELOPMENT_TEAM` y, si hace falta, `BUNDLE_ID_PREFIX` y `APP_GROUP_IDENTIFIER`.
2. Instala la app en el iPhone con Xcode (esquema `AIGamingCoach`, configuración Debug).
3. Batería por encima del 50 %, sin modo de bajo consumo y sin cargar, para no falsear el estado térmico.
4. Anota la versión de Fortnite (Ajustes del juego → al final del menú).

## Procedimiento (una sesión)

| Paso | Qué hacer | Qué observar |
|---|---|---|
| A | Abrir la app → **Start Coaching** → la hoja de iOS debe tener *AI Gaming Coach* preseleccionado → *Start Broadcast* | Home: "Screen capture: Connected" y el banner rojo |
| B | Abrir Fortnite | Si la captura sobrevive a abrir Fortnite (16a) |
| C | Entrar en una partida (Zero Build) | 16b; si el juego pierde fluidez (14) y si el audio suena normal (15) |
| D | Jugar al menos un combate | 16c; si el iPhone se calienta (13) |
| E | Salir un momento a otra app y volver a Fortnite | 16d |
| F | Volver a la app Coach **sin parar** el broadcast. En Debug, el contador de frames debe seguir subiendo | 16e |
| G | Parar desde el indicador rojo o el Centro de Control | Debe aparecer el Session Summary |
| H | Session Summary → **Device test result** → completar los campos manuales → **Copy DEVICE TEST RESULT** | Pegar el bloque en el registro de pruebas |

Si el broadcast se corta solo en algún momento, anota en qué paso (17). Una sesión que termina sin cerrarse, porque iOS mató la extensión, aparece como *"ended without finishing (capture process terminated?)"*.

## Qué mide cada punto y de dónde sale

| # | Campo | Fuente |
|---|---|---|
| 1 | Modelo de iPhone | Manual + identificador de hardware automático (p. ej. `iPhone16,1`) |
| 2 | Versión de iOS | Automático (`ProcessInfo.operatingSystemVersionString`) |
| 3 | Versión de Fortnite | Manual |
| 4 | Duración de la sesión | Automático (reloj de pared) + estado final |
| 5 | Frames recibidos | Automático |
| 6 | FPS de entrada medio | Automático. Excluye el tiempo en pausa |
| 7 | Frames procesados | Automático. Análisis limitado a 10 fps por diseño |
| 8 | Frames perdidos por motivo | Automático: `encoderNotReady`, `analysisBusy`, `keyframeBusy`, `invalidBuffer`, `encoderFailed` |
| 9 | % de frames negros | Automático. Luma media < 0,02 en los frames analizados; "not measured" si el formato de píxel no se pudo leer |
| 10 | Memoria pico de la extensión | Automático. `phys_footprint` (la cifra que usa jetsam), muestreada cada segundo; más el margen mínimo de `os_proc_available_memory` |
| 11 | Memoria media de la extensión | Automático, con la misma muestra |
| 12 | Disco del buffer circular | Automático: pico y valor final de los segmentos en disco, más el total codificado |
| 13 | Estado térmico | Automático (`ProcessInfo.thermalState`: peor valor y valor final; cada cambio queda en la timeline) + manual "se notó caliente" |
| 14 | ¿Fortnite pierde FPS visiblemente? | Manual |
| 15 | ¿El audio de Fortnite sigue normal? | Manual |
| 16 | Supervivencia de la captura en 5 momentos | Manual, contrastado con el contador de frames y la timeline |
| 17 | ¿El broadcast se detuvo inesperadamente? | Manual + estado de sesión automático |
| 18 | Valores del Session Summary | Automático |

Extra, también automático: CPU del proceso de captura (media y pico, 100 % = un núcleo) y latencia de captura, medida como tiempo desde el PTS del frame hasta que empieza a procesarse. La latencia solo se registra si el PTS usa el reloj del host. Si no, aparece como "not measured" y se cuentan las muestras descartadas.

## Formato del resultado

El botón **Copy DEVICE TEST RESULT** genera exactamente este bloque. **Share as JSON** genera los mismos datos en JSON para compararlos con scripts o en una hoja de cálculo.

```
DEVICE TEST RESULT (schema 1)
session: <uuid>
recorded: <fecha ISO 8601>
capture provider: ReplayKit (Broadcast Upload Extension)
app version: 0.1.0

1. iPhone model: <manual> (<identificador>)
2. iOS version: <automático>
3. Fortnite version: <manual>
4. session duration: <m s> (<s> s) — finished normally | failed: … | ended without finishing (capture process terminated?)
5. frames received: <n>
6. average input FPS: <n>
7. frames processed: <n> (avg <n> fps)
8. dropped frames: <n> (<%>) — <motivo>=<n>, …
   source frames without image: none
9. black frames: <%> | not measured
10. peak memory (capture process): <MB> · lowest headroom <MB>
11. average memory (capture process): <MB>
12. rolling-buffer disk: peak <MB>, at end <MB>; total encoded <MB>
13. thermal state: worst <estado>, at end <estado>; felt hot: yes|no|not tested
    CPU (capture process): avg <%>, peak <%>
    capture latency: avg <ms>, max <ms>
14. Fortnite frame rate visibly degraded: yes|no|not tested
15. Fortnite audio normal: yes|no|not tested
16. capture survived — opening Fortnite: …; joining a match: …; combat: …; app switching: …; returning to Coach: …
17. broadcast stopped unexpectedly: yes|no|not tested
18. session summary: keyframes <n>, segments <n>, video <WxH> orientation <n>, storage errors <n>
Fortnite performance notes: …
notes: …
```

## Criterio de aprobado del Milestone 1

- 5 > 0 y la sesión termina en *finished normally*.
- 9 ≈ 0 %. Si no, Fortnite o iOS entregan contenido protegido, y eso bloquea el enfoque.
- 10 deja margen por debajo del límite de la extensión: el margen mínimo (*lowest headroom*) no debe acercarse a 0.
- 16: la captura sobrevive a los cinco momentos.
- 14 y 15: sin degradación apreciable. Si la hay, anota cuánta en *Fortnite performance notes*.

Hasta tener al menos una sesión que cumpla esto no se continúa: ni la comparación de proveedores ni el Milestone 2.
