# Resultados en dispositivo

## 1 — ReplayKit, iPhone15,4 (iPhone 15), iOS 26.3.1, 27‑09‑2026

Build de Xcode 27, cuenta personal (Personal Team). Fortnite (versión sin anotar), partida real de 13 m 31 s.

| Medida | Valor |
|---|---|
| Frames recibidos | 48 480 (59,8 fps de media) |
| Frames procesados | 8 097 (10,0 fps, límite configurado) |
| Frames perdidos | 0 |
| Frames casi negros | 1 (0,01 %) |
| Memoria de la extensión | pico 10,0 MB · media 8,0 MB |
| CPU de la extensión | media 7 % · pico 14 % |
| Tiempo de análisis | 0,16 ms por frame |
| Estado térmico | nominal → fair (0:38) → serious (5:18), serious al final |
| Buffer circular en disco | pico 47,1 MB; 164 segmentos escritos, 145 eliminados; 90 s al final |
| Vídeo codificado en total | 415,2 MB |
| Keyframes | 162 (el de las 00:05 ya muestra Fortnite; los de 05:55 y 06:00 muestran gameplay con HUD) |
| Fin de sesión | `captureFinished`, normal |

Observaciones:

- **La captura sobrevivió a toda la partida.** Hay gameplay en los keyframes desde las 00:05 y el vídeo del final (12:00–13:30) es de la partida.
- **Resolución durante el juego: 408×886** (vertical, marcada con la orientación 6). En la app y en el menú eran 886×1918. ReplayKit entrega Fortnite a una resolución menor, algo a tener en cuenta para leer números del HUD en el Milestone 2.
- **Bug de orientación (corregido después de esta prueba):** keyframes y vídeo salían girados 180°. La marca de orientación de ReplayKit se interpreta al revés en los casos de 90°; `BroadcastPipeline.orientation(of:)` ya intercambia izquierda y derecha. Pendiente de verificar en la siguiente prueba.
- **Temperatura:** llegó a `serious` a los 5 min. Falta saber cuánto se debe a Fortnite y cuánto a la captura; hay que comparar con una partida sin captura.
