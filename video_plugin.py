"""Copia local del plugin de video (Smart Video Wallpaper Reborn) que le dice al puente en que
segundo va el video, para que los colores del fondo de video vayan exactos.

Desde fuera solo se puede estimar el momento del video (la lectura del archivo va por delante y
el plugin pausa el video cuando hay ventanas maximizadas). Esta copia, en
~/.local/share/plasma/wallpapers/<id> (Plasma la usa en vez de la del sistema), agrega SOLO un
Timer que cada 0,5 s hace GET http://127.0.0.1:8765/videopos?f=&t=&d=&p= con el archivo, la
posicion y duracion en ms y si esta reproduciendo. En el lock screen no corre (lockScreenMode).

Uso:  python3 video_plugin.py --install | --remove | --status
El puente llama a ensure() al arrancar: si el plugin del sistema cambio (actualizacion), rehace
la copia; si el cambio ya no encaja, la quita y queda el plugin original.
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile

PLUGIN_ID = "luisbocanegra.smart.video.wallpaper.reborn"
SYSTEM = os.path.join("/usr/share/plasma/wallpapers", PLUGIN_ID)
LOCAL = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
                     "plasma", "wallpapers", PLUGIN_ID)
MARKER = ".cava-viz-patch.json"
ANCHOR = "    contextualActions: [\n"
PATCH = """    // cava-viz: le dice al puente en que segundo va el video (colores sincronizados con el fondo)
    Timer {
        id: cavaVizReport
        interval: 500
        repeat: true
        running: !main.lockScreenMode
        onTriggered: {
            const p = player.player
            if (!p || !main.currentSource || !main.currentSource.filename) return
            const x = new XMLHttpRequest()
            x.open("GET", "http://127.0.0.1:8765/videopos?f=" + encodeURIComponent(main.currentSource.filename)
                   + "&t=" + Math.round(p.position) + "&d=" + Math.round(p.duration) + "&p=" + (p.playing ? 1 : 0))
            x.send()
        }
    }

"""


def fingerprint(root=SYSTEM):
    """Huella del plugin del sistema (cambia si se actualiza)."""
    h = hashlib.sha1()
    for dirpath, _, files in sorted(os.walk(root)):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            h.update(p[len(root):].encode())
            with open(p, "rb") as fh:
                h.update(fh.read())
    return h.hexdigest()


def status():
    if not os.path.isdir(LOCAL):
        return {"installed": False, "ours": False, "stale": False}
    try:
        with open(os.path.join(LOCAL, MARKER)) as f:
            m = json.load(f)
    except (OSError, ValueError):
        return {"installed": True, "ours": False, "stale": False}
    return {"installed": True, "ours": True,
            "stale": os.path.isdir(SYSTEM) and m.get("fingerprint") != fingerprint()}


def install():
    """Crea o rehace la copia parcheada. Atomico: se arma en temporal y se cambia de golpe."""
    st = status()
    if st["installed"] and not st["ours"]:
        raise RuntimeError(f"{LOCAL} existe y no lo creo cava-viz; no se toca")
    if not os.path.isdir(SYSTEM):
        raise RuntimeError(f"No esta instalado el plugin de video en {SYSTEM}")
    main_qml = os.path.join(SYSTEM, "contents", "ui", "main.qml")
    with open(main_qml, encoding="utf-8") as f:
        text = f.read()
    if text.count(ANCHOR) != 1:
        raise RuntimeError("main.qml del plugin cambio en esta version; no se puede agregar el aviso")
    patched = text.replace(ANCHOR, PATCH + ANCHOR, 1)
    os.makedirs(os.path.dirname(LOCAL), exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".cava-viz-plugin-", dir=os.path.dirname(LOCAL))
    try:
        stage = os.path.join(tmp, PLUGIN_ID)
        shutil.copytree(SYSTEM, stage, symlinks=True)
        with open(os.path.join(stage, "contents", "ui", "main.qml"), "w", encoding="utf-8") as f:
            f.write(patched)
        with open(os.path.join(stage, MARKER), "w") as f:
            json.dump({"fingerprint": fingerprint()}, f)
        if os.path.isdir(LOCAL):
            os.rename(LOCAL, os.path.join(tmp, "old"))
        os.rename(stage, LOCAL)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def remove():
    st = status()
    if not st["installed"]:
        return False
    if not st["ours"]:
        raise RuntimeError(f"{LOCAL} no lo creo cava-viz; no se borra")
    shutil.rmtree(LOCAL)
    return True


def ensure(log=print):
    """Deja la copia lista sin que el usuario haga nada: la crea si falta y la rehace si el plugin
    del sistema cambio. Si el aviso ya no encaja con la version nueva, la quita (queda el plugin
    original). No toca una copia que no sea de cava-viz. Devuelve True si escribio una copia
    nueva (Plasma necesita recargar el fondo para usarla)."""
    if not os.path.isdir(SYSTEM):
        return False
    st = status()
    if st["installed"] and not st["ours"]:
        return False
    if st["installed"] and not st["stale"]:
        return False
    try:
        install()
        log("Copia del plugin de video " + ("rehecha (el plugin se actualizo)" if st["installed"] else "creada"))
        return True
    except (OSError, RuntimeError) as e:
        if st["installed"]:
            remove()
        log(f"No se pudo preparar la copia del plugin de video ({e}); se usa el plugin original")
        return False


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "--status"
    try:
        if action == "--install":
            install()
            print(f"Plugin de video con aviso para cava-viz en {LOCAL}")
        elif action == "--remove":
            print("Copia del plugin quitada" if remove() else "No habia copia del plugin")
        else:
            print(json.dumps(status()))
    except (OSError, RuntimeError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
