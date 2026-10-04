"""Puente entre cava y el widget Cava Viz.

Endpoints (solo 127.0.0.1):
  /                              último frame de cava ("12;45;80;...")
  /pause, /resume                congela / reanuda cava (pantalla completa)
  /bars?n=N                      cambia la cantidad de barras y reinicia cava
  /palette?cid=&aspect=          colores vivos del wallpaper (JSON)
  /zones?n=&l=&r=&aspect=&cid=   un color por barra según la zona del wallpaper (JSON)
  /next                          cambia al siguiente wallpaper de la rotación
"""
import colorsys
import json
import os
import random
import re
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
IMG_EXT = (".jpg", ".jpeg", ".png", ".webp")
PORT = 8765

latest = b"0"
proc = None
paused = False
lock = threading.Lock()
current_wallpaper = None          # lo fija la rotación; si es None se lee de la config de Plasma
rotate_now = threading.Event()    # /next lo activa para cambiar de inmediato


def log(msg):
    print(msg, file=sys.stderr, flush=True)  # aparece en: journalctl --user -u cava-bridge


def read_bars():
    m = re.search(r"(?m)^\s*bars\s*=\s*(\d+)", open(CONF).read())
    return int(m.group(1)) if m else 80


bars = read_bars()


# ---------------- cava ----------------

def write_runtime_conf():
    # Copia raw.conf cambiando solo "bars". Tu raw.conf original no se modifica.
    text = open(CONF).read()
    text = re.sub(r"(?m)^\s*bars\s*=.*$", f"bars = {bars}", text)
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
            if paused:
                p.send_signal(signal.SIGSTOP)
        for line in p.stdout:
            latest = line.strip().encode()
        p.wait()
        time.sleep(0.3)  # evita un loop rápido si cava falla al arrancar


def signal_cava(sig):
    with lock:
        if proc and proc.poll() is None:
            proc.send_signal(sig)


def set_bars(n):
    global bars
    n = max(16, min(300, n))
    n -= n % 2  # en stereo cava reparte mitad y mitad
    if n == bars:
        return
    bars = n
    signal_cava(signal.SIGCONT)  # un proceso congelado no procesa SIGTERM
    signal_cava(signal.SIGTERM)  # cava_loop lo relanza con el nuevo número de barras


# ---------------- config de Plasma ----------------

def read_appletsrc():
    """Devuelve {"[seccion]": {clave: valor}} del archivo de config del escritorio."""
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


# ---------------- rotación de wallpapers ----------------

def slideshow_images(data, c):
    # Reutiliza la config de la presentación de Plasma: carpetas, desmarcadas e intervalo
    g = data.get(f"[Containments][{c}][Wallpaper][org.kde.slideshow][General]", {})
    dirs = [d for d in g.get("SlidePaths", "").split(",") if d]
    unchecked = set(g.get("UncheckedSlides", "").split(","))
    interval = int(g.get("SlideInterval", 600))
    files = []
    for d in dirs:
        for folder, _, names in os.walk(d):
            for n in names:
                p = os.path.join(folder, n)
                if n.lower().endswith(IMG_EXT) and p not in unchecked:
                    files.append(p)
    return sorted(files), interval


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w") as f:
        json.dump(state, f)


def rotation_loop():
    global current_wallpaper
    queue = []
    while True:
        wait = 60
        try:
            data = read_appletsrc()
            c = find_containment(data, -1)
            files, interval = slideshow_images(data, c) if c else ([], 600)
            # El último cambio se guarda en disco: el intervalo continúa después de reiniciar
            remaining = interval - (time.time() - load_state().get("last", 0))
            if files and (remaining <= 0 or rotate_now.is_set()):
                queue = [f for f in queue if f in files]
                if not queue:  # orden aleatorio sin repetir hasta recorrer toda la carpeta
                    queue = files[:]
                    random.shuffle(queue)
                path = queue.pop()
                r = subprocess.run(["plasma-apply-wallpaperimage", path], capture_output=True, text=True)
                if r.returncode == 0:
                    current_wallpaper = path
                    save_state({"last": time.time()})
                    log(f"Wallpaper: {path}")
                else:
                    log(f"plasma-apply-wallpaperimage falló: {r.stderr.strip()}")
                remaining = interval
            wait = max(5, min(remaining, 60))  # revisa al menos cada minuto
        except Exception as e:
            log(f"Error en la rotación: {e}")
        rotate_now.clear()
        rotate_now.wait(timeout=wait)


# ---------------- colores del wallpaper ----------------

_cache = {"key": None, "img": None}


def wallpaper_info(cid):
    """Devuelve (ruta de la imagen, FillMode) del wallpaper actual."""
    data = read_appletsrc()
    c = find_containment(data, cid)
    if c is None:
        return None, 2
    g = data.get(f"[Containments][{c}][Wallpaper][org.kde.image][General]", {})
    fill = int(g.get("FillMode", 2))  # 2 = recortar al centro (default de Plasma), 0 = estirar
    path = current_wallpaper or unquote(g.get("Image", "").replace("file://", "", 1))
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
        img = Image.open(path).convert("RGB")
        img.thumbnail((800, 800))
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
        _cache.update(key=key, img=img)
    return _cache["img"]


def vividness(rgb):
    _, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
    return s * v


def boost(rgb, min_v=0.6):
    # Conserva el tono pero aclara colores muy oscuros para que las barras se vean sobre el fondo
    h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
    r, g, b = colorsys.hsv_to_rgb(h, s, max(v, min_v))
    return [round(r * 255), round(g * 255), round(b * 255)]


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
        # Ordena por viveza y presencia; el brillo pesa un poco para imágenes apagadas
        h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
        items.append(((s * v + 0.1 * v) * count ** 0.5, rgb))
    items.sort(reverse=True)
    return [boost(rgb) for _, rgb in items]


def zones(img, n, left, right):
    w, h = img.size
    x0 = int(left * w)
    x1 = max(x0 + 1, int(right * w))
    # BOX promedia bloques: cada columna queda dividida en 48 celdas promedio
    cells = img.crop((x0, 0, x1, h)).resize((n, 48), Image.Resampling.BOX).load()
    cols = []
    for i in range(n):
        # El color más vivo de la columna, no el promedio (el fondo oscuro dominaría)
        best = max((cells[i, j] for j in range(48)), key=vividness)
        cols.append(best if vividness(best) > 0.15 else None)

    # Columnas sin color vivo (fondo oscuro/gris): interpola entre las columnas vivas más cercanas
    vivid = [i for i, c in enumerate(cols) if c is not None]
    if not vivid:
        pal = palette(img)
        return [pal[0] if pal else [128, 128, 128]] * n
    for i in range(n):
        if cols[i] is not None:
            continue
        left_i = max((v for v in vivid if v < i), default=None)
        right_i = min((v for v in vivid if v > i), default=None)
        if left_i is None:
            cols[i] = cols[right_i]
        elif right_i is None:
            cols[i] = cols[left_i]
        else:
            t = (i - left_i) / (right_i - left_i)
            a, b = cols[left_i], cols[right_i]
            cols[i] = tuple(round(a[k] + (b[k] - a[k]) * t) for k in range(3))

    # Suavizado 1-2-1 para que el color no salte entre barras vecinas
    out = []
    for i in range(n):
        a, b, c = cols[max(0, i - 1)], cols[i], cols[min(n - 1, i + 1)]
        out.append(boost([round((a[k] + 2 * b[k] + c[k]) / 4) for k in range(3)]))
    return out


# ---------------- HTTP ----------------

class Handler(BaseHTTPRequestHandler):
    def send(self, body, ctype="text/plain"):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global paused
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}

        if url.path == "/pause":
            paused = True
            signal_cava(signal.SIGSTOP)
        elif url.path == "/resume":
            paused = False
            signal_cava(signal.SIGCONT)
        elif url.path == "/bars":
            set_bars(int(q.get("n", bars)))
        elif url.path == "/next":
            rotate_now.set()
        elif url.path in ("/palette", "/zones"):
            colors = []
            try:
                img = load_image(q.get("cid", "-1"), float(q.get("aspect", 0)))
                if img is not None:
                    if url.path == "/palette":
                        colors = palette(img)
                    else:
                        colors = zones(img, int(q.get("n", bars)),
                                       float(q.get("l", 0)), float(q.get("r", 1)))
            except Exception as e:
                log(f"Error al leer colores del wallpaper: {e}")
            return self.send(json.dumps({"colors": colors}).encode(), "application/json")

        self.send(latest)

    def log_message(self, *args):
        pass


threading.Thread(target=cava_loop, daemon=True).start()
threading.Thread(target=rotation_loop, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
