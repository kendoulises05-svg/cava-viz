"""Puente entre cava y el widget Cava Viz.

Endpoints (solo 127.0.0.1):
  /                                   último frame de cava ("12;45;80;...")
  /pause, /resume                     congela / reanuda cava (una ventana tapa el widget)
  /disable, /enable, /toggle          apaga / enciende el visualizer a mano (persiste tras reiniciar)
  /state                              "off" si está apagado a mano, "on" si no
  /terminal?pause=1|0                 pausar o no el widget mientras otro cava corre (ej. en Konsole)
  /bars?n=N&ch=stereo|mono&fps=F      cambia barras, canales y frames por segundo, y reinicia cava
  (apagado a mano, "/" responde "D"; en pausa por ventana o bloqueo, responde "P")
  /palette?cid=&aspect=               colores vivos del wallpaper (JSON)
  (las dos responden también "bg": el color del fondo detrás de cada barra, con n, l, r, t, b)
  /zones?n=&l=&r=&swap=&aspect=&cid=  un color por barra según la columna del wallpaper, siempre
                                      vivo y claro; swap=1 intercambia esos colores (JSON)
  /rotation?enabled=&dir=&seconds=&order=    config de la rotación (la manda el widget)
  /next                               cambia al siguiente wallpaper
  /wefetch[?show=all|videos|images|?mute=toggle]   atajos de la presentacion de we-fetch (JSON)
  /videopos?f=&t=&d=&p=               posicion exacta del fondo de video (la manda la copia del
                                      plugin, video_plugin.py); sin parametros: lo ultimo recibido
"""
import colorsys
import hashlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

try:
    from PIL import Image
except ImportError:
    Image = None
    print("Pillow no está instalado: los colores del wallpaper no funcionarán", file=sys.stderr, flush=True)

CONF = os.path.expanduser("~/.config/cava/raw.conf")
RUNTIME_CONF = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "cava-viz.conf")
APPLETSRC = os.path.expanduser("~/.config/plasma-org.kde.plasma.desktop-appletsrc")
STATE = os.path.expanduser("~/.local/state/cava-viz/rotation.json")
DISABLED_FLAG = os.path.expanduser("~/.local/state/cava-viz/disabled")  # existe = apagado a mano
IMG_EXT = (".jpg", ".jpeg", ".png", ".webp")
# Fondo de video (Smart Video Wallpaper Reborn, el que pone we-fetch): los colores salen de un
# fotograma del video actual y "Siguiente wallpaper" pasa al siguiente video en vez de poner una imagen
VIDEO_PLUGIN = "luisbocanegra.smart.video.wallpaper.reborn"
FRAMES = os.path.expanduser("~/.cache/cava-viz/frames")
PORT = 8765

ORDER_RANDOM, ORDER_ALPHA, ORDER_NEWEST = 0, 1, 2

latest = b"0"
proc = None
pause_reasons = set()             # "covered", "lock", "manual" y/o "terminal": mientras haya alguna, cava está congelado
terminal_pause = True             # el widget lo cambia con /terminal (opción del panel)
if os.path.exists(DISABLED_FLAG):
    pause_reasons.add("manual")   # se apagó a mano antes de reiniciar: sigue apagado
lock = threading.Lock()           # protege el proceso de cava
state_lock = threading.Lock()     # protege el archivo de estado de la rotación
rotate_now = threading.Event()    # /next lo activa; varios clics durante un cambio se juntan en uno
QDBUS = shutil.which("qdbus6") or shutil.which("qdbus")
APPLY_GRACE = 10                  # segundos que Plasma puede tardar en escribir la imagen en su config


def log(msg):
    print(msg, file=sys.stderr, flush=True)  # aparece en: journalctl --user -u cava-bridge


def read_bars():
    m = re.search(r"(?m)^\s*bars\s*=\s*(\d+)", open(CONF).read())
    return int(m.group(1)) if m else 80


def read_channels():
    m = re.search(r"(?m)^\s*channels\s*=\s*(\w+)", open(CONF).read())
    return m.group(1) if m and m.group(1) in ("stereo", "mono") else "stereo"


bars = read_bars()
channels = read_channels()
fps = 60


# ---------------- cava ----------------

def write_runtime_conf():
    # Copia raw.conf cambiando solo "bars", "channels" y "framerate". Tu raw.conf original no se modifica.
    text = open(CONF).read()
    text = re.sub(r"(?m)^\s*bars\s*=.*$", f"bars = {bars}", text)
    if re.search(r"(?m)^\s*framerate\s*=", text):
        text = re.sub(r"(?m)^\s*framerate\s*=.*$", f"framerate = {fps}", text)
    else:
        text = re.sub(r"(?m)^\[general\]\s*$", f"[general]\nframerate = {fps}", text, count=1)
    if re.search(r"(?m)^\s*channels\s*=", text):
        text = re.sub(r"(?m)^\s*channels\s*=.*$", f"channels = {channels}", text)
    else:
        # raw.conf sin la línea: se agrega justo debajo de [output]
        text = re.sub(r"(?m)^\[output\]\s*$", f"[output]\nchannels = {channels}", text, count=1)
    with open(RUNTIME_CONF, "w") as f:
        f.write(text)


def cava_loop():
    # Mantiene cava vivo. Si termina (cambio de barras o fallo), lo relanza con la config actual.
    global proc, latest
    while True:
        write_runtime_conf()
        p = subprocess.Popen(["cava", "-p", RUNTIME_CONF], stdout=subprocess.PIPE, text=True)
        with lock:
            proc = p
            if pause_reasons:  # cava relanzado durante una pausa: nace congelado
                p.send_signal(signal.SIGSTOP)
        for line in p.stdout:
            latest = line.strip().encode()
        p.wait()
        time.sleep(0.3)  # evita un loop rápido si cava falla al arrancar


def signal_cava(sig):
    with lock:
        if proc and proc.poll() is None:
            proc.send_signal(sig)


def set_audio(n, ch, f):
    global bars, channels, fps
    n = max(16, min(300, n))
    n -= n % 2  # en stereo cava reparte mitad y mitad
    ch = ch if ch in ("stereo", "mono") else channels
    f = max(15, min(60, f))
    if n == bars and ch == channels and f == fps:
        return
    bars, channels, fps = n, ch, f
    log(f"cava: {bars} barras, {channels}, {fps} fps")
    signal_cava(signal.SIGCONT)  # un proceso congelado no procesa SIGTERM
    signal_cava(signal.SIGTERM)  # cava_loop lo relanza con la config nueva


def update_pause(why):
    # Una sola función decide: si queda alguna razón de pausa, cava se congela
    signal_cava(signal.SIGSTOP if pause_reasons else signal.SIGCONT)
    log(f"{why} -> " + (f"cava en pausa {sorted(pause_reasons)}" if pause_reasons else "cava activo"))


def set_manual(off):
    if off == ("manual" in pause_reasons):
        return
    os.makedirs(os.path.dirname(DISABLED_FLAG), exist_ok=True)
    if off:
        pause_reasons.add("manual")
        open(DISABLED_FLAG, "w").close()
    else:
        pause_reasons.discard("manual")
        if os.path.exists(DISABLED_FLAG):
            os.remove(DISABLED_FLAG)
    update_pause("Apagado a mano" if off else "Encendido a mano")


def lock_loop():
    # Pregunta a Plasma cada 2 s si la pantalla está bloqueada
    was_locked = False
    while True:
        locked = False
        if QDBUS:
            try:
                r = subprocess.run([QDBUS, "org.freedesktop.ScreenSaver", "/ScreenSaver",
                                    "org.freedesktop.ScreenSaver.GetActive"],
                                   capture_output=True, text=True, timeout=5)
                locked = r.stdout.strip() == "true"
            except Exception:
                pass  # si D-Bus no responde, se asume desbloqueado (no congela el visualizer por error)
        if locked != was_locked:
            if locked:
                pause_reasons.add("lock")
            else:
                pause_reasons.discard("lock")
            update_pause("Pantalla bloqueada" if locked else "Pantalla desbloqueada")
            was_locked = locked
        time.sleep(2)


def other_cava_running():
    # Algún cava que no sea el del puente (ej. el que abres en Konsole). Se lee /proc directo:
    # son unos cientos de archivos pequeños, más barato que lanzar pgrep cada 2 s.
    own = proc.pid if proc else None
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == own:
            continue
        try:
            with open(f"/proc/{d}/comm") as f:
                if f.read().strip() == "cava":
                    return True
        except OSError:
            pass  # el proceso terminó mientras se recorría la lista
    return False


def terminal_loop():
    # Revisa cada 2 s si hay otro cava abierto; si la opción está activa, pausa el del widget
    was = False
    seen = False
    while True:
        running = other_cava_running()
        if running and not seen:
            # Recién abierto: se pinta con el wallpaper actual. La espera de 1 s es porque
            # SIGUSR2 antes de que cava instale su manejador lo cerraría.
            time.sleep(1)
            update_terminal_cava(load_state().get("applied"))
        seen = running
        now = terminal_pause and running
        if now != was:
            if now:
                pause_reasons.add("terminal")
            else:
                pause_reasons.discard("terminal")
            update_pause("cava abierto en terminal" if now else "cava de terminal cerrado")
            was = now
        time.sleep(2)


# ---------------- config de Plasma ----------------

_appletsrc = {"mtime": None, "data": None}


def read_appletsrc():
    """Devuelve {"[seccion]": {clave: valor}} del archivo de config del escritorio. Se vuelve a
    leer solo si el archivo cambio (con fondo de video el widget consulta cada 0,5 s)."""
    try:
        mtime = os.stat(APPLETSRC).st_mtime_ns
    except OSError:
        mtime = None
    if mtime is not None and mtime == _appletsrc["mtime"]:
        return _appletsrc["data"]
    data = _read_appletsrc_file()
    _appletsrc.update(mtime=mtime, data=data)
    return data


def _read_appletsrc_file():
    data = {}
    section = None
    with open(APPLETSRC, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("["):
                section = line
                data.setdefault(section, {})
            elif section and "=" in line:
                k, v = line.split("=", 1)
                data[section][k] = v
    return data


def find_containment(data, cid):
    # 1) el id que manda el widget  2) si no sirve, el escritorio que contiene este widget
    if f"[Containments][{cid}]" in data:
        return str(cid)
    for sec, kv in data.items():
        if kv.get("plugin") == "org.kendo.cavaviz":
            m = re.match(r"\[Containments\]\[(\d+)\]\[Applets\]", sec)
            if m:
                return m.group(1)
    return None


def image_group(data, c):
    return data.get(f"[Containments][{c}][Wallpaper][org.kde.image][General]", {})


def wallpaper_plugin(data, c):
    return data.get(f"[Containments][{c}]", {}).get("wallpaperplugin", "")


def video_group(data, c):
    return data.get(f"[Containments][{c}][Wallpaper][{VIDEO_PLUGIN}][General]", {})


def video_entries(data, c):
    """Lista VideoUrls del plugin de video (lista de dicts) o [] si no se puede leer."""
    try:
        entries = json.loads(video_group(data, c).get("VideoUrls", "") or "[]")
    except ValueError:
        return []
    return [e for e in entries if isinstance(e, dict)]


VIDEO_EXT = (".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v")
_shell = {"pid": None, "fds": {}, "at": 0.0, "seen": {}}   # plasmashell, sus videos {ruta: fd} y desde cuando


def _plasmashell_pid():
    pid = _shell["pid"]
    if pid:
        try:
            with open(f"/proc/{pid}/comm") as f:
                if f.read().strip() == "plasmashell":
                    return pid
        except OSError:
            pass
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                with open(f"/proc/{d}/comm") as f:
                    if f.read().strip() == "plasmashell":
                        _shell.update(pid=d, fds={}, at=0.0)
                        return d
            except OSError:
                continue
    _shell.update(pid=None, fds={})
    return None


def _video_fds():
    """{ruta: fd} de los videos que plasmashell tiene abiertos. Se revisan los fd ya conocidos en
    cada consulta (barato) y la lista completa solo cada 2 s o si alguno cambio."""
    pid = _plasmashell_pid()
    if not pid:
        return {}
    known = _shell["fds"]
    ok = True
    for path, fd in known.items():
        try:
            ok = ok and os.readlink(f"/proc/{pid}/fd/{fd}") == path
        except OSError:
            ok = False
    if ok and known and time.time() - _shell["at"] < 2:
        return known
    found = {}
    try:
        fds = sorted(os.listdir(f"/proc/{pid}/fd"), key=int, reverse=True)  # fd mas alto = abierto despues
    except OSError:
        fds = []
    for fd in fds:
        try:
            t = os.readlink(f"/proc/{pid}/fd/{fd}")
        except OSError:
            continue
        if t.lower().endswith(VIDEO_EXT) and t not in found:
            found[t] = fd
    now = time.time()
    seen = {p: _shell["seen"].get(p, now) for p in found}
    # el que lleva mas tiempo abierto va primero: el plugin abre el SIGUIENTE video unos segundos
    # antes del cambio (precarga y fundido) y ese aun no se ve
    found = dict(sorted(found.items(), key=lambda kv: seen[kv[0]]))
    _shell.update(fds=found, at=now, seen=seen)
    return found


def playing_videos():
    """Videos que plasmashell tiene abiertos ahora (el que se ve; dos durante la precarga o el
    fundido), del que lleva mas tiempo abierto al mas nuevo. El plugin NO actualiza LastVideo mientras reproduce (ni en
    disco ni en memoria), asi que esta es la forma fiable de saber cual se ve."""
    return list(_video_fds())


def current_video(data, c):
    """Ruta del video que esta en el fondo: el que plasmashell tiene abierto (si esta en la lista
    del plugin); si no, LastVideo si sigue en la lista, y si no el primero activado."""
    on = [unquote(e.get("filename", "").replace("file://", "", 1))
          for e in video_entries(data, c) if e.get("enabled", True)]
    fresh = [p for p, r in reports.items() if time.monotonic() - r["at"] <= REPORT_FRESH and p in on]
    if fresh:
        return max(fresh, key=lambda p: reports[p]["at"])   # el plugin dice cual se ve
    for path in playing_videos():
        if path in on:
            return path
    last = unquote(video_group(data, c).get("LastVideo", "").replace("file://", "", 1))
    return last if last in on else (on[0] if on else None)


FRAME_STEP = 4          # segundos entre fotogramas sueltos (mientras el video aun no esta preparado)
TIMELINES_MAX = 30      # videos preparados que se guardan
TIMELINE_FPS = 2        # fotogramas por segundo al preparar un video (los cortes caen con +-0,25 s)
live = {"video": False}  # el fondo actual es un video: el widget consulta colores mas seguido
FRAMES_MAX = 400        # fotogramas en cache como maximo (se borran los mas viejos)
_durations = {}


def video_duration(path):
    key = (path, os.path.getmtime(path))
    if key not in _durations:
        try:
            r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                               capture_output=True, text=True, timeout=15)
            _durations[key] = float(r.stdout.strip())
        except (ValueError, OSError, subprocess.TimeoutExpired):
            _durations[key] = 0.0
    return _durations[key]


def video_position(path):
    """Segundo que se esta viendo, estimado por cuanto del archivo ha leido plasmashell
    (/proc/<pid>/fdinfo: pos). El lector va un poco por delante: se resta 1 s. None si no lo
    tiene abierto (pausado o cerrado)."""
    size, dur = os.path.getsize(path), video_duration(path)
    fd = _video_fds().get(path)
    if not size or not dur or fd is None:
        return None
    try:
        with open(f"/proc/{_shell['pid']}/fdinfo/{fd}") as f:
            pos = int(next(l for l in f if l.startswith("pos:")).split()[1])
    except (OSError, StopIteration, ValueError, TypeError):
        return None
    return max(0.0, min(dur, pos / size * dur - 1.0))


def _prune_frames():
    try:
        files = sorted((os.path.join(FRAMES, f) for f in os.listdir(FRAMES) if f.endswith(".jpg")),
                       key=os.path.getmtime)
    except OSError:
        return
    for f in files[:-FRAMES_MAX]:
        try:
            os.remove(f)
        except OSError:
            pass


def video_key(path):
    return hashlib.sha1(f"{path}:{os.path.getmtime(path)}".encode()).hexdigest()[:16]


def timeline_dir(path):
    return os.path.join(FRAMES, f"timeline{TIMELINE_FPS}-" + video_key(path))


def prepare_timeline(path):
    """TIMELINE_FPS fotogramas por segundo de todo el video, de una pasada y con prioridad baja. Con la
    decodificacion por hardware (VA-API) cuesta ~2 s de CPU para un video de 97 s 1080p60; sin
    ella se usan solo los fotogramas clave (~1 s de CPU, menos precision). True si quedo listo."""
    d = timeline_dir(path)
    if os.path.isfile(os.path.join(d, ".done")):
        return True
    tmp = d + ".tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)
    out = os.path.join(tmp, "%05d.jpg")
    attempts = []
    if os.path.exists("/dev/dri/renderD128"):
        attempts.append(["-hwaccel", "vaapi", "-hwaccel_output_format", "vaapi", "-i", path,
                         "-vf", f"fps={TIMELINE_FPS},scale_vaapi=w=320:h=180,hwdownload,format=nv12"])
    attempts.append(["-skip_frame", "nokey", "-threads", "1", "-i", path, "-vf", f"fps={TIMELINE_FPS},scale=320:-2"])
    for args in attempts:
        try:
            r = subprocess.run(["nice", "-n", "19", "ffmpeg", "-v", "error", "-y", *args, "-q:v", "6", out],
                               capture_output=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if r.returncode == 0 and os.listdir(tmp):
            write_segments(tmp)
            open(os.path.join(tmp, ".done"), "w").close()
            shutil.rmtree(d, ignore_errors=True)
            os.rename(tmp, d)
            _prune_timelines()
            return True
        for f in os.listdir(tmp):
            os.remove(os.path.join(tmp, f))
    shutil.rmtree(tmp, ignore_errors=True)
    return False


CUT_DIFF = 22           # diferencia media (0-255) entre fotogramas seguidos que cuenta como cambio de escena
DRIFT_DIFF = 45         # o diferencia acumulada desde el inicio del tramo (cambios lentos)
SEG_MAX = 3.0           # un tramo nunca dura mas que esto: en cambios lentos el color sigue al video


def _tiny(path):
    """Fotograma reducido a 16x9 (lista de valores RGB) para comparar colores rapido."""
    with Image.open(path) as im:
        return list(im.convert("RGB").resize((16, 9)).tobytes())


def _diff(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def write_segments(d):
    """Divide el video en tramos de color estable (cambios de escena) y guarda segments.json:
    [[inicio_s, fin_s, fotograma_representativo], ...]."""
    frames = sorted(f for f in os.listdir(d) if f.endswith(".jpg"))
    if Image is None or not frames:
        return
    vecs = [_tiny(os.path.join(d, f)) for f in frames]
    cuts, start = [0], 0
    longest = max(1, int(SEG_MAX * TIMELINE_FPS))
    for i in range(1, len(vecs)):
        if (_diff(vecs[i], vecs[i - 1]) > CUT_DIFF or _diff(vecs[i], vecs[start]) > DRIFT_DIFF
                or i - start >= longest):
            cuts.append(i)
            start = i
    cuts.append(len(vecs))
    # en segundos; el color sale del PRIMER fotograma del tramo (el del corte; numerados desde 1).
    # El del medio, o el segundo, adelantaban el color
    segs = [[a / TIMELINE_FPS, b / TIMELINE_FPS, a + 1] for a, b in zip(cuts, cuts[1:])]
    with open(os.path.join(d, "segments.json"), "w") as f:
        json.dump(segs, f)


def load_segments(path):
    d = timeline_dir(path)
    try:
        with open(os.path.join(d, "segments.json")) as f:
            return d, json.load(f)
    except (OSError, ValueError):
        return d, None


def segment_at(segs, t):
    for i, (a, b, _) in enumerate(segs):
        if a <= t < b:
            return i
    return len(segs) - 1


# --- reloj del video -----------------------------------------------------------------
# El reproductor lee el archivo por delante y a tirones, asi que la posicion de lectura se
# adelanta. El reloj cuenta tiempo real desde que empieza el video (o vuelve a empezar al
# repetirse); la lectura solo detecta inicio, repeticion y desfases grandes (pausa).
LEAD = 1.0              # segundos que la lectura va por delante (medido en plasmashell: 0,6-1,5 s, varia con la escena)
RESYNC = 3.0            # si reloj y lectura difieren mas que esto (p. ej. tras una pausa), se corrige
_clocks = {}
# Posicion exacta que manda la copia del plugin de video (video_plugin.py): {ruta: {...}}
reports = {}
REPORT_FRESH = 2.0      # segundos que vale un aviso del plugin (llega cada 0,5 s)
EXACT_DELAY = 0.15      # con la posicion exacta solo queda lo que tarda en pintarse (0,1 iba 0,05 s adelantado)


def reported_position(path):
    """Segundo exacto del video segun el plugin, o None si no hay aviso reciente."""
    r = reports.get(path)
    if not r or time.monotonic() - r["at"] > REPORT_FRESH:
        return None
    t = r["t"] + (time.monotonic() - r["at"] if r["playing"] else 0.0)
    return t % r["d"] if r["d"] > 0 else t


def video_clock(path):
    fd = _video_fds().get(path)
    if fd is None:
        _clocks.pop(path, None)
        return None
    try:
        size, dur = os.path.getsize(path), video_duration(path)
        with open(f"/proc/{_shell['pid']}/fdinfo/{fd}") as f:
            pos = int(next(l for l in f if l.startswith("pos:")).split()[1])
    except (OSError, StopIteration, ValueError, TypeError):
        return None
    if not size or not dur:
        return None
    now = time.monotonic()
    est = max(0.0, pos / size * dur - LEAD)       # lo que dice la lectura
    c = _clocks.get(path)
    if c is None or pos < c["pos"] - size * 0.3:
        # primera vez (o el puente arranco a mitad): por la lectura. Volvio a empezar: la lectura
        # llega al principio LEAD segundos ANTES de que se vea el reinicio (lee por delante), asi
        # que el reloj arranca en -LEAD (el final de la vuelta anterior)
        start = est if c is None else -LEAD
        c = _clocks[path] = {"t0": now - start, "pos": pos}
    c["pos"] = pos
    t = (now - c["t0"]) % dur          # -LEAD % dur = dur - LEAD: los ultimos segundos de la vuelta
    if abs(t - est) > RESYNC and pos < size * 0.98:
        c["t0"] = now - est                         # pausa o salto: se vuelve a la lectura
        t = est
    return t


def _prune_timelines():
    try:
        dirs = sorted((os.path.join(FRAMES, x) for x in os.listdir(FRAMES) if x.startswith("timeline") and not x.endswith(".tmp")),
                      key=os.path.getmtime)
    except OSError:
        return
    for d in dirs[:-TIMELINES_MAX]:
        shutil.rmtree(d, ignore_errors=True)


# ---------------- copia del plugin de video: automatica ----------------
WATCH_EVERY = 10        # segundos entre revisiones
SILENT_RELOAD = 15      # fondo de video sin aviso del plugin durante esto => recargar el fondo
_reloaded_for = set()   # pid de plasmashell en el que ya se recargo el fondo (una vez por sesion)


def reload_video_wallpaper():
    """Recarga el plugin de los escritorios con fondo de video para que Plasma use la copia
    nueva, sin reiniciar el escritorio: lo cambia a imagen y, 1,5 s despues, vuelve al de video
    (en un mismo script Plasma ignora el cambio). La config del video se conserva."""
    if not QDBUS:
        return False
    run = lambda js: subprocess.run([QDBUS, "org.kde.plasmashell", "/PlasmaShell",
                                     "org.kde.PlasmaShell.evaluateScript", js],
                                    capture_output=True, text=True, timeout=15)
    r = run("var ids = []; desktops().forEach(function (d) {"
            f" if (d.wallpaperPlugin === {json.dumps(VIDEO_PLUGIN)}) {{ ids.push(d.id); d.wallpaperPlugin = 'org.kde.image'; }}"
            "}); print(ids.join(','));")
    ids = [int(x) for x in r.stdout.strip().split(",") if x.strip().isdigit()]
    if not ids:
        return False
    time.sleep(1.5)
    for attempt in range(3):     # volver al video siempre, aunque el primer intento falle
        r = run(f"var ids = {json.dumps(ids)}; desktops().forEach(function (d) {{"
                f" if (ids.indexOf(d.id) >= 0) d.wallpaperPlugin = {json.dumps(VIDEO_PLUGIN)}; }});")
        if r.returncode == 0:
            return True
        time.sleep(1)
    log(f"No se pudo volver al fondo de video tras recargarlo: {r.stdout.strip() or r.stderr.strip()}")
    return False


def plugin_watch_loop():
    """Sin comandos del usuario: mantiene la copia del plugin y que Plasma la use."""
    try:
        import video_plugin
    except ImportError as e:
        log(f"No se encontro video_plugin.py ({e}): colores del video aproximados")
        return
    started = time.monotonic()
    while True:
        try:
            written = video_plugin.ensure(log)
            data = read_appletsrc()
            c = find_containment(data, -1)
            is_video = c is not None and wallpaper_plugin(data, c) == VIDEO_PLUGIN
            pid = _plasmashell_pid()
            # silencio desde el ultimo aviso (o desde que arranco el puente: la lista empieza vacia)
            last = max([r["at"] for r in reports.values()] + [started])
            silent = time.monotonic() - last > SILENT_RELOAD
            ours = video_plugin.status()["ours"]
            if is_video and ours and pid and (written or (silent and playing_videos() and pid not in _reloaded_for)):
                _reloaded_for.add(pid)
                ok = reload_video_wallpaper()
                log("Fondo de video recargado para usar la copia del plugin" if ok
                    else "No habia fondo de video que recargar")
        except Exception as e:
            log(f"Error vigilando el plugin de video: {e}")
        time.sleep(WATCH_EVERY)


def prepare_loop():
    """Prepara en segundo plano el video que se esta viendo (una vez por video)."""
    # al arrancar: tramos de videos preparados con una version anterior (barato: solo compara)
    try:
        for x in os.listdir(FRAMES):
            d = os.path.join(FRAMES, x)
            if x.startswith("timeline") and os.path.isfile(os.path.join(d, ".done")) \
                    and not os.path.isfile(os.path.join(d, "segments.json")):
                write_segments(d)
    except OSError:
        pass
    while True:
        try:
            data = read_appletsrc()
            c = find_containment(data, -1)
            if c is not None and wallpaper_plugin(data, c) == VIDEO_PLUGIN:
                for path in playing_videos():
                    d = timeline_dir(path)
                    if os.path.isfile(os.path.join(d, ".done")) and not os.path.isfile(os.path.join(d, "segments.json")):
                        write_segments(d)            # tramos de una version anterior: se recalculan
                    if not os.path.isfile(os.path.join(d, ".done")):
                        log(f"Preparando colores del video: {os.path.basename(path)}")
                        log("listo" if prepare_timeline(path) else "no se pudo preparar; se usan fotogramas sueltos")
        except Exception as e:
            log(f"Error preparando colores del video: {e}")
        time.sleep(3)


ANTICIPATE = 0.25       # la transicion de color del widget dura esto: se empieza antes del corte
# Ajuste fino del momento (segundos que se retrasan los colores). Lo que tarda el reproductor en
# mostrar un fotograma y el widget en pintar; probado a ojo: con 0 los colores iban 0,5 s adelantados
VIEW_DELAY = 0.5


def video_segment(path):
    """Tramo de color actual y el siguiente de un video preparado:
    {"frame": jpg del tramo, "next": jpg del siguiente, "in": ms hasta el corte} o None."""
    d, segs = load_segments(path)
    if not segs:
        return None
    if _clocks.get("_current") != path:
        # paso a verse otro video: su reloj empieza ahora (pudo abrirse antes, por la precarga)
        _clocks.pop(path, None)
        _clocks["_current"] = path
    exact = reported_position(path)
    if exact is not None:
        t = max(0.0, exact - EXACT_DELAY)
    else:
        t = video_clock(path)
        if t is None:
            t = video_duration(path) / 3
        else:
            t = (t - VIEW_DELAY) % max(video_duration(path), 0.001)
    i = segment_at(segs, t + ANTICIPATE)
    out = {"frame": os.path.join(d, f"{segs[i][2]:05d}.jpg"), "next": None, "in": None}
    if len(segs) > 1:
        j = (i + 1) % len(segs)
        start = segs[i][1] if j else video_duration(path)   # el ultimo tramo enlaza con el primero
        out.update(next=os.path.join(d, f"{segs[j][2]:05d}.jpg"),
                   **{"in": max(0, int((start - t - ANTICIPATE) * 1000))})
    return out


def video_frame(path, at=None):
    """Fotograma del video en el segundo 'at' como JPG. Si el video ya esta preparado, el de ese
    segundo; si no, uno suelto cada FRAME_STEP s (en cache). Sin 'at': a un tercio del video
    (el principio suele ser negro)."""
    if not path or not os.path.isfile(path) or not shutil.which("ffmpeg"):
        return None
    dur = video_duration(path)
    if at is None:
        at = dur / 3 if dur else 3
    d = timeline_dir(path)
    if os.path.isfile(os.path.join(d, ".done")):
        n = len([f for f in os.listdir(d) if f.endswith(".jpg")])
        if n:
            return os.path.join(d, f"{min(n, int(at * TIMELINE_FPS) + 1):05d}.jpg")
    at = int(at // FRAME_STEP) * FRAME_STEP
    key = video_key(path)
    out = os.path.join(FRAMES, f"{key}-{at:05d}.jpg")
    if os.path.isfile(out):
        return out
    os.makedirs(FRAMES, exist_ok=True)
    for ss in (str(at), "0"):
        # -ss antes de -i: salta directo; -skip_frame nokey: solo decodifica el fotograma clave mas
        # cercano (medido: 0.11 s de CPU frente a 0.85 s), que para sacar colores sobra
        r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-skip_frame", "nokey", "-threads", "1", "-ss", ss,
                            "-i", path, "-frames:v", "1", "-vf", "scale=320:-2", out],
                           capture_output=True, timeout=30)
        if r.returncode == 0 and os.path.isfile(out) and os.path.getsize(out) > 0:
            if len([f for f in os.listdir(FRAMES) if f.endswith(".jpg")]) > FRAMES_MAX:
                _prune_frames()
            return out
    return None


def next_video(data, c):
    """Pasa el fondo de video al siguiente: gira una posicion la lista de videos activados (el
    plugin, al ver la lista nueva, muestra el que queda en la posicion actual). Devuelve (ok, detalle)."""
    entries = video_entries(data, c)
    on = [i for i, e in enumerate(entries) if e.get("enabled", True)]
    if len(on) < 2:
        return False, "solo hay un video en el fondo"
    vids = [entries[i] for i in on]
    vids = vids[1:] + vids[:1]
    for i, e in zip(on, vids):
        entries[i] = e
    if not QDBUS:
        return False, "no se encontro qdbus6"
    script = (
        "desktops().forEach(function (d) {"
        f" if (d.wallpaperPlugin !== {json.dumps(VIDEO_PLUGIN)}) return;"
        f" d.currentConfigGroup = ['Wallpaper', {json.dumps(VIDEO_PLUGIN)}, 'General'];"
        f" d.writeConfig('VideoUrls', {json.dumps(json.dumps(entries, separators=(',', ':')))});"
        " d.reloadConfig();"
        "});"
    )
    r = subprocess.run([QDBUS, "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell.evaluateScript", script],
                       capture_output=True, text=True, timeout=15)
    return r.returncode == 0, (r.stdout.strip() or r.stderr.strip())


def configured_image(data, c):
    """Imagen que Plasma tiene puesta en modo Imagen (o un fotograma del video, si el fondo es de
    video), o None si usa presentación u otro plugin."""
    plugin = wallpaper_plugin(data, c)
    live["video"] = plugin == VIDEO_PLUGIN
    if plugin != VIDEO_PLUGIN:
        last_segment["seg"] = None
    if plugin == VIDEO_PLUGIN:
        path = current_video(data, c)
        seg = video_segment(path) if path else None
        last_segment["seg"] = seg
        if seg:
            return seg["frame"]
        # aun sin preparar: fotograma del momento que se ve (o uno fijo si esta en pausa)
        return video_frame(path, video_position(path) if path else None)
    if plugin != "org.kde.image":
        return None  # en presentación Plasma no expone la imagen actual
    value = image_group(data, c).get("Image", "")
    return unquote(value.replace("file://", "", 1)) or None


# ---------------- rotación de wallpapers ----------------

def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)  # escritura atómica: un corte de luz no deja el archivo a medias


def rotation_settings(state, data, c):
    # Lo que mande el widget tiene prioridad; si falta algo, se usa la presentación de Plasma
    g = data.get(f"[Containments][{c}][Wallpaper][org.kde.slideshow][General]", {})
    s = state.get("settings", {})
    dirs = [s["dir"]] if s.get("dir") else [d for d in g.get("SlidePaths", "").split(",") if d]
    return {
        "enabled": s.get("enabled", True),
        "dirs": dirs,
        "interval": s.get("interval") or int(g.get("SlideInterval", 600)),
        "order": s.get("order", ORDER_RANDOM),
        "unchecked": set(g.get("UncheckedSlides", "").split(",")),
    }


def list_images(dirs, unchecked):
    files = []
    for d in dirs:
        for folder, _, names in os.walk(d):
            for n in names:
                p = os.path.join(folder, n)
                if n.lower().endswith(IMG_EXT) and p not in unchecked:
                    files.append(p)
    return files


def build_deck(files, order, current):
    if order == ORDER_RANDOM:
        deck = files[:]
        random.shuffle(deck)
        if len(deck) > 1 and deck[0] == current:  # no repetir la que ya está puesta
            deck.append(deck.pop(0))
        return deck
    if order == ORDER_ALPHA:
        deck = sorted(files, key=lambda p: os.path.basename(p).casefold())
    else:  # ORDER_NEWEST
        deck = sorted(files, key=os.path.getmtime, reverse=True)
    # Empieza justo después de la imagen actual para continuar la secuencia
    if current in deck:
        i = deck.index(current) + 1
        deck = deck[i:] + deck[:i]
    return deck


def apply_wallpaper(path):
    """Pone el wallpaper en Plasma. Devuelve (ok, detalle)."""
    r = subprocess.run(["plasma-apply-wallpaperimage", path],
                       capture_output=True, text=True, timeout=15)
    if r.returncode == 0:
        return True, ""
    detail = (f"código {r.returncode} | stdout: {r.stdout.strip() or '-'}"
              f" | stderr: {r.stderr.strip() or '-'}")
    if "'" not in path or not QDBUS:
        return False, detail
    # plasma-apply-wallpaperimage rechaza nombres con comilla simple porque arma su script
    # con la ruta entre comillas simples. Aquí se envía el mismo script por D-Bus, y
    # json.dumps convierte la ruta en un texto JavaScript válido aunque tenga comillas.
    script = (
        "var ds = desktops();"
        "for (var i = 0; i < ds.length; i++) {"
        " ds[i].wallpaperPlugin = 'org.kde.image';"
        " ds[i].currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];"
        f" ds[i].writeConfig('Image', {json.dumps('file://' + path)});"
        "}"
    )
    r2 = subprocess.run([QDBUS, "org.kde.plasmashell", "/PlasmaShell",
                         "org.kde.PlasmaShell.evaluateScript", script],
                        capture_output=True, text=True, timeout=15)
    if r2.returncode == 0:
        return True, "aplicado por D-Bus: el nombre tiene comilla simple"
    return False, f"{detail} | D-Bus: {r2.stdout.strip() or r2.stderr.strip() or '-'}"


WE_FETCH_TURNS_UNIT = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                                   "systemd", "user", "we-fetch-desktop-turns.service")


def we_fetch_turns():
    """we-fetch tiene activas las imagenes por turnos con los videos del escritorio."""
    return os.path.isfile(WE_FETCH_TURNS_UNIT)


WE_FETCH_CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "we-fetch")


def we_fetch_exe():
    # el servicio puede no tener ~/.local/bin (pipx) en el PATH
    return shutil.which("we-fetch") or next((p for p in [os.path.expanduser("~/.local/bin/we-fetch")]
                                             if os.path.isfile(p)), None)


def we_fetch_status():
    """Para el menu del widget: si we-fetch maneja el escritorio, que muestra y si esta en silencio.
    Se lee de sus archivos (sin lanzar we-fetch en cada consulta)."""
    active = os.path.isfile(os.path.join(WE_FETCH_CONFIG, "desktop-applied.json"))
    if not active or not we_fetch_exe():
        return {"available": False}
    try:
        with open(os.path.join(WE_FETCH_CONFIG, "screens.json"), encoding="utf-8") as f:
            d = json.load(f).get("desktop") or {}
    except (OSError, ValueError):
        d = {}
    return {"available": True, "show": d.get("show") or "all", "muted": not d.get("audio", False)}


_we_fetch_lock = threading.Lock()


def we_fetch_quick(q):
    """/wefetch?show=all|videos|images o ?mute=toggle: se lo pide a we-fetch (lo guarda y lo pone).
    De a uno: si llega otro mientras corre, se ignora (no se apilan procesos)."""
    exe = we_fetch_exe()
    if exe and _we_fetch_lock.acquire(blocking=False):
        try:
            _we_fetch_run(exe, q)
        finally:
            _we_fetch_lock.release()


def _we_fetch_run(exe, q):
    if q.get("show") in ("all", "videos", "images"):
        args = ["show", q["show"]]
    elif q.get("mute") in ("on", "off", "toggle"):
        args = ["mute", q["mute"]]
    else:
        return
    r = subprocess.run([exe, "desktop", *args], capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        log(f"we-fetch desktop {' '.join(args)} fallo | {r.stderr.strip()[-200:]}")


def rotation_step():
    """Revisa si toca cambiar el wallpaper. Devuelve cuántos segundos esperar."""
    state = load_state()
    data = read_appletsrc()
    c = find_containment(data, -1)
    if c is None:
        return 60
    if we_fetch_turns():
        # we-fetch hace la presentacion del escritorio (videos e imagenes, un elemento a la vez):
        # no se rota encima y "Siguiente wallpaper" le pide a we-fetch el siguiente. Va antes que el
        # caso de video: el plugin solo tiene el video actual y no sabria pasar al siguiente
        if rotate_now.is_set():
            rotate_now.clear()
            # el servicio puede no tener ~/.local/bin (pipx) en el PATH
            exe = we_fetch_exe()
            if exe:
                r = subprocess.run([exe, "desktop", "turns-next"], capture_output=True, text=True, timeout=30)
                log("we-fetch: siguiente turno" if r.returncode == 0 else f"we-fetch turns-next fallo | {r.stderr.strip()[-200:]}")
        return 60
    if wallpaper_plugin(data, c) == VIDEO_PLUGIN:
        # Fondo de video: los videos los rota el plugin. Solo se atiende "Siguiente wallpaper"
        # (nunca se pone una imagen encima del video).
        if rotate_now.is_set():
            rotate_now.clear()
            ok, detail = next_video(data, c)
            log("Fondo de video: siguiente video" if ok else f"No se pudo pasar al siguiente video | {detail}")
            if ok:
                time.sleep(2)  # el plugin tarda un momento en guardar LastVideo
                update_terminal_cava(configured_image(read_appletsrc(), c))
        return 60
    s = rotation_settings(state, data, c)
    if not s["enabled"]:
        return 60

    current = configured_image(data, c)
    # Si elegiste una imagen a mano en Plasma, se respeta y el intervalo vuelve a empezar
    # (se ignora justo después de que el puente cambió la imagen: Plasma tarda en escribir su config)
    recent = time.time() - state.get("last", 0) < APPLY_GRACE
    if current and state.get("applied") and current != state["applied"] and not recent:
        state.update(applied=current, last=time.time())
        save_state(state)
        log(f"Imagen elegida a mano: {current}")
        update_terminal_cava(current)

    files = list_images(s["dirs"], s["unchecked"])
    remaining = s["interval"] - (time.time() - state.get("last", 0))
    if files and (remaining <= 0 or rotate_now.is_set()):
        rotate_now.clear()
        file_set = set(files)
        deck = [f for f in state.get("deck", []) if f in file_set]  # quita las que ya no existen
        if not deck or state.get("deck_order") != s["order"]:
            deck = build_deck(files, s["order"], current)
        path = deck[0]  # solo sale de la baraja si Plasma lo acepta
        try:
            ok, detail = apply_wallpaper(path)
        except subprocess.TimeoutExpired:
            log("Plasma tardó más de 15 s en aplicar el wallpaper; se reintenta en el siguiente ciclo")
            return 30
        if ok:
            deck.pop(0)
            state.update(deck=deck, deck_order=s["order"], applied=path, last=time.time())
            save_state(state)
            log(f"Wallpaper: {path}" + (f" ({detail})" if detail else ""))
            update_terminal_cava(path)
        else:
            # El motivo puede salir por stdout o stderr: se registran ambos con el código
            log(f"No se pudo aplicar {path} | {detail}")
            deck.append(deck.pop(0))  # la imagen pasa al final: no se pierde ni bloquea a las demás
            state.update(deck=deck, deck_order=s["order"])
            save_state(state)
            return 10
        remaining = s["interval"]
    return max(5, min(remaining, 60))  # revisa al menos cada minuto


def rotation_loop():
    while True:
        wait = 60
        try:
            with state_lock:
                # rotation_step limpia el aviso antes de cambiar: un clic que llegue
                # mientras Plasma aplica la imagen queda pendiente para la siguiente vuelta
                wait = rotation_step()
        except Exception as e:
            log(f"Error en la rotación: {e}")
            rotate_now.clear()
        rotate_now.wait(timeout=wait)


def update_rotation_settings(q):
    new = {
        "enabled": q.get("enabled", "1") == "1",
        "dir": q.get("dir", ""),
        "interval": max(10, int(q.get("seconds", 54000))),  # segundos; mínimo 10 para no saturar Plasma
        "order": int(q.get("order", ORDER_RANDOM)),
    }
    with state_lock:
        state = load_state()
        if state.get("settings") != new:  # solo escribe si algo cambió
            state["settings"] = new
            save_state(state)


# ---------------- colores del wallpaper ----------------

_cache = {"key": None, "img": None}
_results = {}  # resultados ya calculados; se vacía solo cuando cambia la imagen


_next_img = {}
last_segment = {"seg": None}


def colors_for(img, imgkey, endpoint, n, l, r, t, b, swap):
    """Colores de una imagen para un endpoint, en cache por imagen y parametros."""
    key = (imgkey, endpoint, n, l, r, t, b, swap)
    if key not in _results:
        if len(_results) > 64:
            _results.clear()
        if endpoint == "/palette":
            _results[key] = palette(img)
        elif endpoint == "/bg":
            _results[key] = area_colors(img, n, l, r, t, b)
        else:
            cols = zones(img, n, l, r)
            _results[key] = [vivid(c) for c in swap_colors(cols, img)] if swap else cols
    return _results[key]


def cached(params, compute):
    key = (_cache["key"],) + params
    if key not in _results:
        if len(_results) > 64:
            _results.clear()
        _results[key] = compute()
    return _results[key]


def wallpaper_info(cid):
    """Devuelve (ruta de la imagen, FillMode) del wallpaper actual."""
    data = read_appletsrc()
    c = find_containment(data, cid)
    if c is None:
        return None, 2
    path = configured_image(data, c)
    fill = int(image_group(data, c).get("FillMode", 2))  # 2 = recortar al centro, 0 = estirar
    if path and os.path.isdir(path):
        # Wallpaper tipo paquete (ej. /usr/share/wallpapers/Next): usa la imagen más grande
        imgs = os.path.join(path, "contents", "images")
        files = [os.path.join(imgs, x) for x in os.listdir(imgs)] if os.path.isdir(imgs) else []
        path = max(files, key=os.path.getsize) if files else None
    return (path if path and os.path.isfile(path) else None), fill


def load_image(cid, aspect):
    path, fill = wallpaper_info(cid)
    if not path or Image is None:
        return None
    key = (path, os.path.getmtime(path), round(aspect, 3), fill)
    if _cache["key"] != key:  # solo se recarga si cambia el wallpaper, la pantalla o el modo
        _cache.update(key=key, img=open_image(path, aspect, fill))
    return _cache["img"]


def open_image(path, aspect, fill):
    """Imagen lista para calcular colores: reducida y recortada como la muestra Plasma."""
    if True:
        img = Image.open(path).convert("RGB")
        img.thumbnail((600, 600))
        if fill == 2 and aspect > 0:
            # Igual que Plasma en "Scaled and Cropped": recorte centrado a la proporción de la pantalla
            w, h = img.size
            if w / h > aspect:
                nw = int(h * aspect)
                x = (w - nw) // 2
                img = img.crop((x, 0, x + nw, h))
            else:
                nh = int(w / aspect)
                y = (h - nh) // 2
                img = img.crop((0, y, w, y + nh))
        return img


def vividness(rgb):
    _, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
    return s * v


def boost(rgb, min_v=0.6):
    # Conserva el tono pero aclara colores muy oscuros para que las barras se vean sobre el fondo
    h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
    if v < min_v:
        # En píxeles casi negros el tono es ruido: sin esto un café oscuro se vuelve rojo intenso
        s *= min(1.0, v / 0.3)
    r, g, b = colorsys.hsv_to_rgb(h, s, max(v, min_v))
    return [round(r * 255), round(g * 255), round(b * 255)]


def area_colors(img, n, left, right, top, bottom):
    """Color promedio del fondo detrás de cada barra (solo el área del widget). El widget lo usa
    para oscurecer las barras que no se distinguirían (fondo muy claro o blanco)."""
    w, h = img.size
    x0, y0 = int(left * w), int(top * h)
    x1, y1 = max(x0 + 1, int(right * w)), max(y0 + 1, int(bottom * h))
    cells = img.crop((x0, y0, x1, y1)).resize((n, 1), Image.Resampling.BOX).load()
    return smooth([list(cells[i, 0]) for i in range(n)])


def vivid(rgb):
    """Color de barra que siempre se ve: brillo alto y, si tiene tono, más saturado.
    Un gris queda gris claro (no se inventa un tono)."""
    h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
    s *= min(1.0, v / 0.3)      # en píxeles casi negros el tono es ruido
    if s > 0.12:
        s = min(1.0, max(s * 1.3, 0.55))
    r, g, b = colorsys.hsv_to_rgb(h, s, max(v, 0.82))
    return [round(r * 255), round(g * 255), round(b * 255)]


def smooth(cols):
    # Suavizado 1-2-1 para que el color no salte entre barras vecinas
    n = len(cols)
    out = []
    for i in range(n):
        a, b, c = cols[max(0, i - 1)], cols[i], cols[min(n - 1, i + 1)]
        out.append([round((a[k] + 2 * b[k] + c[k]) / 4) for k in range(3)])
    return out


def palette(img, k=8):
    px = list(img.resize((160, 90)).getdata())
    # Solo los píxeles con color: así un detalle pequeño pero vivo no se pierde en el fondo oscuro
    colored = [p for p in px if vividness(p) > 0.15]
    src = colored if len(colored) >= len(px) * 0.01 else px
    strip = Image.new("RGB", (len(src), 1))
    strip.putdata(src)
    q = strip.quantize(colors=k, method=Image.Quantize.MEDIANCUT)
    pal = q.getpalette()
    items = []
    for count, idx in q.getcolors():
        rgb = tuple(pal[idx * 3: idx * 3 + 3])
        h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
        items.append(((s * v + 0.1 * v) * count ** 0.5, rgb))
    items.sort(reverse=True)
    return [boost(rgb) for _, rgb in items]

TERM_CONF = os.path.expanduser("~/.config/cava/terminal.conf")


def terminal_shades(rgb):
    # 4 tonos del mismo color: base oscura -> punta clara
    h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
    out = []
    for ss, vv in [(s, 0.18), (s, 0.45), (s, 0.80), (s * 0.45, 1.0)]:
        r, g, b = colorsys.hsv_to_rgb(h, ss, vv)
        out.append("#%02X%02X%02X" % (round(r * 255), round(g * 255), round(b * 255)))
    return out


def update_terminal_cava(path):
    """Pinta el cava de Konsole con el color más vivo del wallpaper."""
    if Image is None or not os.path.isfile(TERM_CONF):
        return  # sin Pillow o sin terminal.conf: no hace nada
    if path and os.path.isdir(path):
        path = wallpaper_info(-1)[0]  # wallpaper tipo paquete
    if not path or not os.path.isfile(path):
        return
    try:
        # Se abre aparte para no pisar el _cache que usa el widget
        img = Image.open(path).convert("RGB")
        img.thumbnail((600, 600))
        cols = palette(img)
    except Exception as e:
        log(f"cava terminal: no se pudo leer {path}: {e}")
        return
    if not cols:
        return
    shades = terminal_shades(cols[0])
    with open(TERM_CONF) as f:
        lines = f.readlines()
    for i, line in enumerate(lines):
        key = line.split("=")[0].strip()
        for n in range(4):
            if key == f"gradient_color_{n + 1}":
                lines[i] = f"gradient_color_{n + 1} = '{shades[n]}'\n"
    with open(TERM_CONF, "w") as f:
        f.writelines(lines)
    # SIGUSR2 hace que cava recargue los colores. Solo a procesos que se llaman "cava" y usan
    # terminal.conf: "pkill -f" también le pegaba a cualquier shell con ese texto en su comando
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/comm") as f:
                if f.read().strip() != "cava":
                    continue
            with open(f"/proc/{d}/cmdline", "rb") as f:
                if b"terminal.conf" in f.read():
                    os.kill(int(d), signal.SIGUSR2)
        except OSError:
            pass  # el proceso terminó mientras se recorría la lista
    log(f"cava terminal: {shades}")

def zones(img, n, left, right):
    w, h = img.size
    x0 = int(left * w)
    x1 = max(x0 + 1, int(right * w))
    strip = img.crop((x0, 0, x1, h))
    # BOX promedia bloques: cada columna queda dividida en 48 celdas promedio
    cells = strip.resize((n, 48), Image.Resampling.BOX).load()
    avg = strip.resize((n, 1), Image.Resampling.BOX).load()  # color promedio de cada columna
    cols = []
    for i in range(n):
        # El color más vivo de la columna, no el promedio (el fondo oscuro dominaría)
        best = max((cells[i, j] for j in range(48)), key=vividness)
        cols.append(best if vividness(best) > 0.15 else None)

    # Columnas sin color vivo, agrupadas en tramos seguidos:
    #  - tramo corto entre dos colores vivos -> se interpola (une zonas vecinas)
    #  - tramo largo o en el borde -> usa su propio color real (ej. fondo gris = barras grises)
    max_gap = max(2, n // 8)
    i = 0
    while i < n:
        if cols[i] is not None:
            i += 1
            continue
        j = i
        while j < n and cols[j] is None:
            j += 1
        left_c = cols[i - 1] if i > 0 else None
        right_c = cols[j] if j < n else None
        length = j - i
        for k in range(i, j):
            if left_c is not None and right_c is not None and length <= max_gap:
                t = (k - i + 1) / (length + 1)
                cols[k] = tuple(round(left_c[c] + (right_c[c] - left_c[c]) * t) for c in range(3))
            else:
                cols[k] = avg[k, 0]
        i = j
    return [vivid(c) for c in smooth(cols)]


def color_distance(a, b):
    return sum((a[k] - b[k]) ** 2 for k in range(3)) ** 0.5


def swap_colors(cols, img):
    # Intercambia colores entre zonas: cada barra toma, de los colores presentes,
    # el que MÁS se diferencia del suyo (zorro: naranja <-> azul)
    pool = []
    for c in cols:
        if all(color_distance(c, p) > 60 for p in pool):  # agrupa tonos casi iguales
            pool.append(c)
    if len(pool) < 2:
        # Toda la franja es de un solo color: se completa con la paleta de la imagen
        for c in palette(img):
            if all(color_distance(c, p) > 60 for p in pool):
                pool.append(c)
            if len(pool) == 4:
                break
    if len(pool) < 2:
        return cols
    return smooth([max(pool, key=lambda p: color_distance(p, c)) for c in cols])


# ---------------- HTTP ----------------

_rejected = {"at": -1e9}


class Handler(BaseHTTPRequestHandler):
    def send(self, body, ctype="text/plain"):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def allowed(self):
        """Solo el widget y la copia del plugin de video (Plasma, sin navegador). Escuchar en
        127.0.0.1 no basta: una pagina web abierta en el navegador puede mandar pedidos a
        127.0.0.1 (o leerlos con DNS rebinding). Por eso:
          - Host tiene que ser 127.0.0.1/localhost (un dominio "rebindeado" trae su propio nombre);
          - los navegadores siempre mandan Origin o Sec-Fetch-Site en pedidos de otra pagina;
            el XMLHttpRequest de Plasma no manda ninguno de los dos."""
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()
        if host not in ("127.0.0.1", "localhost", "::1"):
            return False
        if self.headers.get("Origin") is not None:
            return False
        return self.headers.get("Sec-Fetch-Site", "none") in ("none", "same-origin")

    def do_GET(self):
        if not self.allowed():
            now = time.monotonic()
            if now - _rejected["at"] > 60:          # como mucho una linea por minuto en el log
                _rejected["at"] = now
                log(f"Pedido rechazado (no viene del widget): {self.path.split('?')[0]} "
                    f"Host={self.headers.get('Host')} Origin={self.headers.get('Origin')}")
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            return self.route(url, q)
        except (ValueError, TypeError) as e:
            # parametros mal formados: 400 en vez de un traceback en el log
            log(f"Pedido invalido {url.path}: {e}")
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def route(self, url, q):

        if url.path == "/pause":
            if "covered" not in pause_reasons:
                pause_reasons.add("covered")
                update_pause("Ventana tapa el widget")
        elif url.path == "/resume":
            if "covered" in pause_reasons:
                pause_reasons.discard("covered")
                update_pause("Widget visible")
        elif url.path in ("/disable", "/enable", "/toggle"):
            off = url.path == "/disable" or (url.path == "/toggle" and "manual" not in pause_reasons)
            set_manual(off)
        elif url.path == "/terminal":
            global terminal_pause
            terminal_pause = q.get("pause", "1") == "1"
        elif url.path == "/state":
            return self.send(b"off" if "manual" in pause_reasons else b"on")
        elif url.path == "/bars":
            set_audio(int(q.get("n", bars)), q.get("ch", channels), int(q.get("fps", fps)))
        elif url.path == "/wefetch":
            if q:
                we_fetch_quick(q)
            return self.send(json.dumps(we_fetch_status()).encode(), "application/json")
        elif url.path == "/next":
            # Sin filtro de tiempo: la rotación aplica un cambio a la vez, así que los clics
            # que lleguen mientras Plasma aplica uno se juntan en un solo "siguiente"
            rotate_now.set()
        elif url.path == "/rotation":
            try:
                update_rotation_settings(q)
            except Exception as e:
                log(f"Config de rotación inválida: {e}")
        elif url.path == "/videopos":
            # aviso de la copia del plugin de video: archivo, posicion y duracion (ms), reproduciendo.
            # Sin parametros: lo ultimo recibido (para diagnosticar)
            if "f" not in q:
                now = time.monotonic()
                return self.send(json.dumps({os.path.basename(k): {**v, "hace_s": round(now - v["at"], 2)}
                                             for k, v in reports.items()}).encode(), "application/json")
            try:
                f = unquote(q.get("f", "")).replace("file://", "", 1)
                reports[f] = {"t": int(q.get("t", 0)) / 1000, "d": int(q.get("d", 0)) / 1000,
                              "playing": q.get("p", "1") == "1", "at": time.monotonic()}
                if len(reports) > 8:
                    reports.pop(next(iter(reports)))
            except ValueError:
                pass
            return self.send(b"ok")
        elif url.path in ("/palette", "/zones"):
            colors, bg, extra = [], [], {}
            try:
                aspect = float(q.get("aspect", 0))
                img = load_image(q.get("cid", "-1"), aspect)
                if img is not None:
                    n = max(16, min(300, int(q.get("n", bars))))   # acotado: n enorme = memoria enorme
                    # Redondeo: mover el widget 1 px no debe invalidar el caché
                    l, r = round(float(q.get("l", 0)), 3), round(float(q.get("r", 1)), 3)
                    t, b = round(float(q.get("t", 0)), 3), round(float(q.get("b", 1)), 3)
                    swap = q.get("swap", "0") == "1"
                    args = (url.path, n, l, r, t, b, swap)
                    colors = colors_for(img, _cache["key"], *args)
                    bg = colors_for(img, _cache["key"], "/bg", *args[1:])
                    # Fondo de video preparado: tambien los colores del siguiente tramo y cuanto
                    # falta, para que el widget cambie justo en el corte (sin esperar otra consulta)
                    seg = last_segment.get("seg")
                    if live["video"] and seg and seg["next"] and seg["in"] is not None and seg["in"] < 4000:
                        fill = 2
                        nkey = (seg["next"], round(aspect, 3), fill)
                        nimg = _next_img.get(nkey)
                        if nimg is None:
                            _next_img.clear()
                            nimg = _next_img[nkey] = open_image(seg["next"], aspect, fill)
                        extra = {"next": colors_for(nimg, nkey, *args), "in": seg["in"],
                                 "next_bg": colors_for(nimg, nkey, "/bg", *args[1:])}
            except Exception as e:
                log(f"Error al leer colores del wallpaper: {e}")
            return self.send(json.dumps({"colors": colors, "bg": bg, "live": live["video"], **extra}).encode(),
                             "application/json")


        # "D" (apagado a mano) y "P" (pausa) le avisan al widget que oculte las barras
        # y consulte menos seguido
        if "manual" in pause_reasons:
            return self.send(b"D")
        self.send(b"P" if pause_reasons else latest)

    def log_message(self, *args):
        pass


threading.Thread(target=cava_loop, daemon=True).start()
threading.Thread(target=plugin_watch_loop, daemon=True).start()
threading.Thread(target=rotation_loop, daemon=True).start()
threading.Thread(target=lock_loop, daemon=True).start()
threading.Thread(target=terminal_loop, daemon=True).start()
threading.Thread(target=prepare_loop, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
