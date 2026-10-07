# CLAUDE.md — Cava Viz

Contexto para Claude Code. Léelo completo antes de tocar código.

## Usuario y forma de trabajo

- Kendo, estudiante de TICs. Nivel intermedio-básico en Python, Node.js, HTML y Java. Responde **siempre en español**, directo, sin emojis ni relleno. Términos técnicos en inglés.
- Sistema: **Kubuntu 26.04, KDE Plasma 6.6.6, Wayland**, laptop HP. Comandos para bash (Linux).
- Si hay ambigüedad, **preguntar antes de escribir código**. Si hay varios enfoques, compararlos y recomendar uno.
- Para cambios: mostrar solo el bloque que cambia, explicar el porqué, y avisar riesgos o malas prácticas explícitamente.
- Ante errores: primero la causa raíz, luego la solución, y cómo diagnosticarlo él mismo.
- Si no estás seguro de algo (APIs de Plasma 6.6 en especial), dilo. No inventar.
- Antes de cambios grandes: `git add . && git commit -m "Antes de ..." && git push`.

## Qué es el proyecto

Widget visualizador de audio para el escritorio de Plasma 6 (plasmoid QML) con un puente en Python. Repo: `https://github.com/kendoulises05-svg/cava-viz` (GPL-3.0). Carpeta local: `~/cava-viz`.

```
PipeWire/Pulse -> cava (raw, ascii) -> cava_bridge.py (HTTP 127.0.0.1:8765) -> widget QML
                                            |-> rota el wallpaper (plasma-apply-wallpaperimage / D-Bus)
                                            |-> lee la imagen con Pillow y calcula colores
```

QML no puede leer un stream continuo ni archivos locales (`XMLHttpRequest` sobre `file://` está bloqueado en Qt 6), por eso existe el puente HTTP. Se midió que el polling HTTP cuesta solo 2-4% de CPU; **no migrar a websockets** (decisión documentada en el README).

### Archivos

| Archivo | Función |
|---|---|
| `cava_bridge.py` | Puente: proceso de cava, servidor HTTP, rotación de wallpaper, modos de color, pausas |
| `org.kendo.cavaviz/metadata.json` | Metadatos del plasmoid (Id `org.kendo.cavaviz`) |
| `org.kendo.cavaviz/contents/ui/main.qml` | Widget: polling, dibujo, colores, glow, detección de pantalla completa |
| `org.kendo.cavaviz/contents/ui/configWave.qml` | Página Wave: forma, audio, glow, rendimiento (fps), comportamiento |
| `org.kendo.cavaviz/contents/ui/configColor.qml` | Página Color |
| `org.kendo.cavaviz/contents/ui/configWallpaper.qml` | Página Wallpaper (rotación) |
| `org.kendo.cavaviz/contents/config/main.xml` | Claves de configuración (kcfg) |
| `org.kendo.cavaviz/contents/config/config.qml` | Registra las páginas Wave, Color, Wallpaper |
| `terminal.conf` | Plantilla de cava para Konsole con gradiente; el puente reescribe sus colores |
| `tools/bench.sh` | Medición de CPU por escenario |
| `raw.conf` | Config base de cava; el puente escribe una copia en `$XDG_RUNTIME_DIR/cava-viz.conf` cambiando `bars`, `channels`, `framerate` |
| `install.sh` | Instala/actualiza todo (`--uninstall` para quitar). Genera el servicio systemd con la ruta real del repo |
| `README.md`, `README.es.md` | Documentación en inglés y español; incluye sección de rendimiento con mediciones |

### Claves de configuración (main.xml)

`barWidth barGap orientation mirrorLine mirrorOpacity colorMode colorBlend zoneSwap showPeaks peakFall hideOnSilence fps audioChannels bassLayout glowEnabled glowStrength glowColorMode rotationEnabled rotationDir rotationIntervalSec rotationOrder pauseRule terminalPause`

Se leen en QML con `Plasmoid.configuration.<clave>`; en las páginas de config con `property alias cfg_<clave>`.

### Endpoints del puente

| Endpoint | Función |
|---|---|
| `/` | Último frame (`12;45;...`), `P` si cava está en pausa, `D` si está apagado a mano |
| `/pause`, `/resume` | Agrega/quita la razón de pausa `"covered"` (una ventana tapa el widget) |
| `/disable`, `/enable`, `/toggle`, `/state` | Apagado manual (razón `"manual"`, persiste en `~/.local/state/cava-viz/disabled`) |
| `/terminal?pause=1\|0` | Opción `terminalPause` del widget; `terminal_loop` revisa `/proc` cada 2 s y agrega la razón `"terminal"` si corre otro cava |
| `/bars?n=&ch=&fps=` | Barras, `stereo`/`mono` y fps; reinicia cava |
| `/next` | Siguiente wallpaper |
| `/rotation?enabled=&dir=&seconds=&order=` | Config de rotación (estado en `~/.local/state/cava-viz/rotation.json`) |
| `/palette`, `/zones`, `/contrast`, `/auto` | Colores del wallpaper (JSON) |

### Sistema de pausa actual (importante para las tareas)

- En el puente, `pause_reasons` es un `set`. Razones actuales: `"covered"` (la manda el widget), `"manual"` (`/disable`, `/toggle`; persiste) y `"lock"` (hilo `lock_loop` que consulta `org.freedesktop.ScreenSaver.GetActive` cada 2 s). `update_pause()` manda `SIGSTOP` si hay alguna razón y `SIGCONT` si no hay ninguna. Un cava relanzado durante una pausa nace congelado.
- En el widget (`main.qml`): `TaskManager.TasksModel` con `filterByVirtualDesktop`, `filterByActivity`, `filterByScreen`, `filterHidden`; `checkCovered()` (con debounce de 250 ms) aplica `pauseRule`: 0 nunca, 1 `IsFullScreen`, 2 también `IsMaximized`, 3 también si el `Geometry` de las ventanas tapa el 90% de `areaRect` (cuadrícula de puntos, cubre tiling). Al cambiar `coveredActive` llama `/pause` o `/resume`, detiene el polling y oculta las barras.
- Cuando el puente responde `P` o `D`, el widget oculta las barras y baja el polling a 1 por segundo (`bridgePaused`, `manualOff`).
- Medido el 2026-10-04: en pantalla completa cava pasa a estado `T` y los tres procesos caen a ~0% de CPU. **La pausa por pantalla completa funciona**; cualquier cambio no debe romperla.

### Acciones y atajo actuales

- `Plasmoid.contextualActions`: "Siguiente wallpaper" (clic derecho).
- `Connections { target: Plasmoid; function onActivated() }`: el atajo de la página Keyboard Shortcuts del widget llama a `/next`. **Ojo: si la nueva tarea usa ese mismo atajo para activar/desactivar, hay conflicto**; decidir con el usuario.

## Tareas nuevas

### 1. Botón y atajo para desactivar/activar el visualizer

Objetivo: poder apagar Cava Viz a voluntad (botón y atajo de teclado) y volver a encenderlo.

Propuesta (confirmar con el usuario antes de implementar):
- Puente: nueva razón de pausa `"manual"` y endpoint `/toggle` (o `/disable` y `/enable`). Decidir si el estado manual debe **persistir tras reiniciar** (guardarlo en el estado o en la config del widget).
- Widget: acción en `contextualActions` "Desactivar visualizer"/"Activar visualizer" (texto según el estado); al desactivar, ocultar las barras y bajar el polling (igual que con `P`).
- Atajo: el atajo nativo del plasmoid es uno solo (`onActivated`). Opciones: (a) usarlo para activar/desactivar y dejar "Siguiente wallpaper" en un atajo personalizado de System Settings con `curl -s http://127.0.0.1:8765/next`; (b) al revés. Preguntar cuál prefiere.
- Alternativa sin depender de Plasma: atajos personalizados de System Settings que llamen `curl` a los endpoints.

### 2. Mejorar la detección de pantalla completa / maximizada

Petición literal del usuario: "mejorar el código cuando pasa a pantalla completa de desactive, y active cuando está maximizada".

**Ambigüedad a confirmar antes de programar**:
- ¿Qué falla hoy exactamente? La medición mostró que la pausa en pantalla completa funciona. Pedir un caso concreto (qué app, qué pasó).
- "Active cuando está maximizada": ¿significa que con una ventana **maximizada** (no pantalla completa) el visualizer debe **seguir activo**, o que **también** debe pausarse? Una ventana maximizada tapa el widget, así que pausar ahorraría CPU; pero puede que el usuario quiera verlo en un monitor o detrás de ventanas transparentes.
- Posible mejora general: hacer configurable la regla de pausa (solo pantalla completa / también maximizada / nunca), por ejemplo un ComboBox en Wave > Rendimiento. `AbstractTasksModel` tiene el rol `IsMaximized` (verificar que existe en Plasma 6.6 antes de usarlo).
- Revisar casos borde: ventana en pantalla completa en otro escritorio virtual o minimizada (los filtros del TasksModel deberían excluirlas), y que `onDataChanged`/`onCountChanged` disparen bien al salir de pantalla completa.

## Cómo probar y medir

```bash
# Aplicar cambios
systemctl --user restart cava-bridge          # tras editar cava_bridge.py o raw.conf
cd ~/cava-viz && ./install.sh                  # tras editar el widget (pregunta si recargar Plasma)
plasmawindowed org.kendo.cavaviz               # probar el widget en ventana, ve errores QML en la terminal
                                               # (la detección de pantalla completa NO funciona aquí)

# Logs
journalctl --user -u cava-bridge -n 20 --no-pager
journalctl --user -u plasma-plasmashell -n 30 --no-pager | grep -iE "cavaviz|qml"

# Estado de cava: S/R activo, T pausado
for i in $(seq 15); do ps -o stat= -C cava; sleep 1; done

# CPU de plasmashell (10 muestras, valor instantáneo)
for i in $(seq 1 10); do top -b -n 2 -d 0.5 -p $(pgrep -x plasmashell) | awk '/^top -/{f++} f==2 && $1 ~ /^[0-9]+$/ {print "plasmashell cpu=" $9 "%"}'; done
```

Medir con `tools/bench.sh` (guiado) o `tools/bench.sh --now "etiqueta"` (estado actual); resultados en `~/.local/state/cava-viz/bench/`. Referencia 2026-10-07 (194 barras, 45 fps, glow, espejo): activo 33.9% total (plasmashell 28.7%), pausado 8.5% (todo de plasmashell: panel y otros widgets miden ~9% con Cava Viz apagado). Una mejora no debe empeorar estos números; medir antes y después.

cava en Konsole con colores del wallpaper: `cava -p ~/.config/cava/terminal.conf` (plantilla `terminal.conf` del repo, la copia `install.sh`). `update_terminal_cava()` reescribe `gradient_color_1..4` y manda `SIGUSR2` solo a procesos con comm `cava` y `terminal.conf` en el cmdline (**no usar `pkill -f`**: le pega a cualquier shell con ese texto en su comando). Un `cava` sin `-p` usa `~/.config/cava/config` y no recibe colores.

**Lección: el puente pierde barras/canales/fps al reiniciarse** (vuelve a `raw.conf`). El widget los reenvía cada 2 s en el Timer de colores; sin eso, con menos barras de las esperadas solo se dibuja la parte izquierda.

## Lecciones aprendidas (errores que ya pasaron)

- **Nombres de propiedad QML**: `gc` es ilegal (choca con la función global `gc()`); da "Illegal property name". No usar nombres de globales de JS.
- **`readonly` + `Behavior`**: no se puede animar una propiedad `readonly`.
- **ComboBox con modelo dinámico**: cambiar el `model` puede reiniciar `currentIndex`; usar modelos fijos.
- **Valores que no son índice** (ej. fps 30/45/60): `property int cfg_fps` + `onActivated`, no alias a `currentIndex`.
- **No reiniciar `plasma-plasmashell` varias veces seguidas**: systemd bloquea con "start request repeated too quickly". Recuperar con `systemctl --user reset-failed plasma-plasmashell && systemctl --user start plasma-plasmashell`. `install.sh` pregunta antes de recargar por esto.
- **Quitar el widget del escritorio borra su configuración** (Plasma la guarda por instancia). El código y el puente no se afectan.
- **`plasma-apply-wallpaperimage` rechaza nombres con comilla simple**; el puente usa un respaldo por D-Bus (`evaluateScript` con la ruta escapada con `json.dumps`).
- **La presentación (slideshow) de Plasma no expone la imagen actual** (ni en el archivo de config ni por D-Bus); por eso el puente tiene su propia rotación.
- **Optimización de frames repetidos**: si se omite un frame igual al anterior, en silencio hay que seguir contando `silentCount` y dejando caer peaks/glow; si no, el widget no se oculta.
- **Rendimiento**: el costo dominante es el dibujo, no el polling. Calcular algo por barra en cada frame (ej. la opacidad del glow en cada rectángulo) multiplicó el CPU por 3; calcular una vez por capa lo resolvió.
- **Python**: el servicio usa `/usr/bin/python3`; Pillow se instala con `apt install python3-pil`, no con pip. El `python3` de la terminal del usuario puede ser otro intérprete.
- **Descargas** del usuario están en `~/Descargas`, no `~/Downloads`.
- `git add` con una ruta inexistente cancela todo el comando.

## Commit final de cada tarea

```bash
cd ~/cava-viz && git add . && git commit -m "<descripción>" && git push
```

Actualizar `README.md` y `README.es.md` si cambia una función visible (endpoints, opciones del panel, atajos).
