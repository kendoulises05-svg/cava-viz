#!/usr/bin/env bash
# Instala o actualiza Cava Viz: dependencias, config de cava, servicio del puente y widget.
#
# Uso:
#   ./install.sh               instalar o actualizar (se puede ejecutar las veces que quieras)
#   ./install.sh --uninstall   quitar servicio y widget (no toca raw.conf ni tus wallpapers)

set -euo pipefail  # detenerse ante cualquier error o variable sin definir

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # carpeta donde está este script
PLASMOID_ID="org.kendo.cavaviz"
SERVICE="cava-bridge.service"
SERVICE_DIR="$HOME/.config/systemd/user"
CAVA_CONF="$HOME/.config/cava/raw.conf"

info() { echo -e "\e[36m[cava-viz]\e[0m $*"; }
warn() { echo -e "\e[33m[cava-viz] AVISO:\e[0m $*"; }
fail() { echo -e "\e[31m[cava-viz] ERROR:\e[0m $*" >&2; exit 1; }

# ---------- Desinstalar ----------
if [[ "${1:-}" == "--uninstall" ]]; then
    info "Deteniendo el puente..."
    systemctl --user disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$SERVICE_DIR/$SERVICE"
    systemctl --user daemon-reload
    info "Quitando el widget..."
    kpackagetool6 -t Plasma/Applet -r "$PLASMOID_ID" 2>/dev/null || true
    info "Listo. raw.conf y tus wallpapers no se tocaron."
    exit 0
fi

# ---------- 1. Dependencias ----------
command -v kpackagetool6 >/dev/null || fail "No existe kpackagetool6: este script es para KDE Plasma 6."

missing=()
command -v cava >/dev/null || missing+=(cava)
command -v curl >/dev/null || missing+=(curl)
# El servicio usa /usr/bin/python3, así que se verifica ese y no el python3 de tu terminal
/usr/bin/python3 -c "import PIL" 2>/dev/null || missing+=(python3-pil)

if (( ${#missing[@]} )); then
    info "Instalando dependencias: ${missing[*]}"
    sudo apt install -y "${missing[@]}"
fi

command -v plasma-apply-wallpaperimage >/dev/null \
    || warn "No existe plasma-apply-wallpaperimage: la rotación de wallpaper no funcionará."

# ---------- 2. Config de cava (nunca sobrescribe la tuya) ----------
if [[ -f "$CAVA_CONF" ]]; then
    info "raw.conf ya existe en $CAVA_CONF, se conserva."
else
    mkdir -p "$(dirname "$CAVA_CONF")"
    cp "$REPO_DIR/raw.conf" "$CAVA_CONF"
    info "raw.conf copiado a $CAVA_CONF"
fi

# ---------- 3. Servicio del puente ----------
# Se genera con la ruta real del repo: funciona aunque lo clones en otra carpeta
mkdir -p "$SERVICE_DIR"
cat > "$SERVICE_DIR/$SERVICE" <<EOF
[Unit]
Description=Puente de cava para el widget Cava Viz
After=pipewire-pulse.service
PartOf=graphical-session.target

[Service]
ExecStart=/usr/bin/python3 "$REPO_DIR/cava_bridge.py"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload
systemctl --user enable "$SERVICE" >/dev/null
systemctl --user restart "$SERVICE"
info "Puente instalado y reiniciado."

# ---------- 4. Widget ----------
cd "$REPO_DIR/$PLASMOID_ID"
if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx "$PLASMOID_ID"; then
    kpackagetool6 -t Plasma/Applet -u . >/dev/null
    info "Widget actualizado."
    FIRST_TIME=0
else
    kpackagetool6 -t Plasma/Applet -i . >/dev/null
    info "Widget instalado."
    FIRST_TIME=1
fi

# ---------- 5. Verificación ----------
sleep 2
if curl -s -m 2 http://127.0.0.1:8765/ >/dev/null; then
    info "El puente responde en el puerto 8765."
else
    warn "El puente no responde. Revisa: journalctl --user -u cava-bridge -n 20 --no-pager"
fi

# ---------- 6. Recargar Plasma (preguntando, para no reiniciarlo varias veces seguidas) ----------
read -rp "¿Recargar el escritorio ahora para aplicar el widget? [s/N] " answer
if [[ "${answer,,}" == "s" ]]; then
    systemctl --user restart plasma-plasmashell
    info "Escritorio recargado."
else
    info "Recárgalo después con: systemctl --user restart plasma-plasmashell"
fi

if (( FIRST_TIME )); then
    info "Primera instalación: clic derecho en el escritorio > Add Widgets > Cava Viz."
fi
info "Listo."
