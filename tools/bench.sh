#!/usr/bin/env bash
# Mide el CPU de Cava Viz: plasmashell (dibuja el widget), cava y el puente.
#
# Uso:
#   tools/bench.sh                  test guiado: activo, pantalla completa, tiling, cava en Konsole, apagado
#   tools/bench.sh --now "nombre"   mide solo lo que hay ahora en pantalla (sin preguntas)
#   SECS=20 tools/bench.sh          cambia la duración de cada medición (por defecto 10 s)
#
# Mide el promedio real de cada intervalo con los ticks de /proc/<pid>/stat (no una muestra
# instantánea como top). plasmashell también dibuja el panel y los otros widgets: para saber
# cuánto es de Cava Viz, compara contra la fila "Apagado manual".
# Resultados: ~/.local/state/cava-viz/bench/

SECS=${SECS:-10}
HZ=$(getconf CLK_TCK)
BRIDGE=http://127.0.0.1:8765
OUT_DIR="$HOME/.local/state/cava-viz/bench"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/bench-$(date +%Y%m%d-%H%M%S).txt"

ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

measure() {
    local label=$1
    # El cava del puente es el que usa cava-viz.conf (puede haber otro abierto en Konsole)
    local ps=$(pgrep -x plasmashell) cv=$(pgrep -f "cava -p .*cava-viz\.conf" | head -1)
    local br=$(pgrep -f cava_bridge.py | head -1)
    local a1=$(ticks "$ps") b1=$(ticks "$cv") c1=$(ticks "$br")
    sleep "$SECS"
    local a2=$(ticks "$ps") b2=$(ticks "$cv") c2=$(ticks "$br")
    local st=$(ps -o stat= -p "$cv" 2>/dev/null | tr -d ' ')
    awk -v l="$label" -v a=$((a2 - a1)) -v b=$((b2 - b1)) -v c=$((c2 - c1)) -v hz="$HZ" -v s="$SECS" -v st="$st" \
        'function p(x) { return x / hz / s * 100 }
         BEGIN { printf "%-28s %10.1f%% %7.1f%% %7.1f%% %7.1f%%   %s\n", l, p(a), p(b), p(c), p(a + b + c), st }' | tee -a "$OUT"
}

header() {
    printf "%-28s %11s %8s %8s %8s   %s\n" "Escenario" "plasmashell" "cava" "puente" "total" "cava" | tee "$OUT"
}

curl -s -m 2 -o /dev/null "$BRIDGE/" || { echo "El puente no responde en $BRIDGE"; exit 1; }

if [[ "${1:-}" == "--now" ]]; then
    header
    measure "${2:-Ahora}"
    exit 0
fi

wait_enter() { echo; read -rp "$1  [Enter]"; }

echo "Pon música y déjala sonando durante todo el test. Cada medición dura $SECS s."
header

wait_enter "1) Escritorio libre: el widget visible, ninguna ventana encima."
sleep 2; measure "Widget visible (activo)"

wait_enter "2) Al dar Enter tienes 5 s para poner un video en pantalla completa. Vuelve en ~$((SECS + 10)) s."
sleep 5; measure "Pantalla completa"

wait_enter "3) Tiling o ventana maximizada tapando el widget (según 'Pausar cuando')."
sleep 2; measure "Ventana tapa el widget"

wait_enter "4) Abre cava en otra Konsole, deja el widget a la vista y vuelve aquí. (Para saltar: Enter sin abrirlo)"
sleep 2; measure "cava en Konsole"

echo; echo "5) Apagado manual (automático, no hagas nada)."
curl -s -o /dev/null "$BRIDGE/disable"
sleep 2; measure "Apagado manual"
curl -s -o /dev/null "$BRIDGE/enable"

echo
echo "Resultados guardados en: $OUT"
echo "Columna cava: S/R = activo, T = congelado. La fila 'Apagado manual' es el consumo"
echo "de plasmashell sin Cava Viz (panel y otros widgets)."
