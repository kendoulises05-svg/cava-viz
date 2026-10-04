"""Puente entre cava y el widget Cava Viz.

Endpoints (solo 127.0.0.1):
  /                                   último frame de cava ("12;45;80;...")
  /pause, /resume                     congela / reanuda cava (pantalla completa)
  /bars?n=N                           cambia la cantidad de barras y reinicia cava
  /palette?cid=&aspect=               colores vivos del wallpaper (JSON)
  /zones?n=&l=&r=&swap=&aspect=&cid=  un color por barra según la columna del wallpaper;
                                      swap=1 intercambia esos colores (JSON)
  /contrast?n=&l=&r=&t=&b=&...        mismo tono que lo que hay detrás, brillo invertido (JSON)
  /rotation?enabled=&dir=&interval=&order=   config de la rotación (la manda el widget)
  /next                               cambia al siguiente wallpaper
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

ORDER_RANDOM, ORDER_ALPHA, ORDER_NEWEST = 0, 1, 2

latest = b"0"
proc = None
paused = False
lock = threading.Lock()           # protege el proceso de cava
state_lock = threading.Lock()     # protege el archivo de estado de la rotación
rotate_now = threading.Event()    # /next lo activa para cambiar de inmediato
last_next = 0.0                   # para ignorar clics repetidos muy seguidos
APPLY_GRACE = 10                  # segundos que Plasma puede tardar en escribir la imagen en su config


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


def image_group(data, c):
    return data.get(f"[Containments][{c}][Wallpaper][org.kde.image][General]", {})


def configured_image(data, c):
    """Imagen que Plasma tiene puesta en modo Imagen, o None si usa presentación u otro plugin."""
    if data.get(f"[Containments][{c}]", {}).get("wallpaperplugin") != "org.kde.image":
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


def rotation_step():
    """Revisa si toca cambiar el wallpaper. Devuelve cuántos segundos esperar."""
    state = load_state()
    data = read_appletsrc()
    c = find_containment(data, -1)
    if c is None:
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

    files = list_images(s["dirs"], s["unchecked"])
    remaining = s["interval"] - (time.time() - state.get("last", 0))
    if files and (remaining <= 0 or rotate_now.is_set()):
        rotate_now.clear()
        file_set = set(files)
        deck = [f for f in state.get("deck", []) if f in file_set]  # quita las que ya no existen
        if not deck or state.get("deck_order") != s["order"]:
            deck = build_deck(files, s["order"], current)
        path = deck.pop(0)
        try:
            # timeout: si Plasma no responde, no se congela toda la rotación
            r = subprocess.run(["plasma-apply-wallpaperimage", path],
                               capture_output=True, text=True, timeout=15)
        except subprocess.TimeoutExpired:
            log("plasma-apply-wallpaperimage tardó más de 15 s; se reintenta en el siguiente ciclo")
            return 30
        if r.returncode == 0:
            state.update(deck=deck, deck_order=s["order"], applied=path, last=time.time())
            save_state(state)
            log(f"Wallpaper: {path}")
        else:
            log(f"plasma-apply-wallpaperimage falló: {r.stderr.strip()}")
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
        "interval": max(60, int(q.get("interval", 900)) * 60),  # el widget manda minutos
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
        _cache.update(key=key, img=img)
    return _cache["img"]


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
    return [boost(c) for c in smooth(cols)]


def color_distance(a, b):
    return sum((a[k] - b[k]) ** 2 for k in range(3)) ** 0.5


def contrast_bright(img, n, left, right, top, bottom):
    # Mismo tono que lo que hay DETRÁS del widget, con el brillo invertido
    w, h = img.size
    x0, y0 = int(left * w), int(top * h)
    x1, y1 = max(x0 + 1, int(right * w)), max(y0 + 1, int(bottom * h))
    cells = img.crop((x0, y0, x1, y1)).resize((n, 1), Image.Resampling.BOX).load()
    cols = []
    for i in range(n):
        r, g, b = cells[i, 0]
        lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255  # brillo percibido (0 negro, 1 blanco)
        hh, s, _ = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        # Fondo oscuro -> barra clara; fondo claro -> barra oscura (transición suave entre 0.4 y 0.6)
        t = min(1.0, max(0.0, (lum - 0.4) / 0.2))
        v = 0.95 * (1 - t) + 0.2 * t
        rr, gg, bb = colorsys.hsv_to_rgb(hh, min(1.0, s * 1.15), v)
        cols.append((round(rr * 255), round(gg * 255), round(bb * 255)))
    return smooth(cols)


def zones_swap(img, n, left, right):
    # Los mismos colores del modo por zona, intercambiados: cada barra toma el color
    # de otra zona que MÁS se diferencia del suyo (zorro: naranja <-> azul)
    z = zones(img, n, left, right)
    pool = []
    for c in z:
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
        return z
    return smooth([max(pool, key=lambda p: color_distance(p, c)) for c in z])


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
        global paused, last_next
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
            if time.time() - last_next > 2:  # ignora clics repetidos en menos de 2 s
                last_next = time.time()
                rotate_now.set()
        elif url.path == "/rotation":
            try:
                update_rotation_settings(q)
            except Exception as e:
                log(f"Config de rotación inválida: {e}")
        elif url.path in ("/palette", "/zones", "/contrast"):
            colors = []
            try:
                img = load_image(q.get("cid", "-1"), float(q.get("aspect", 0)))
                if img is not None:
                    n = int(q.get("n", bars))
                    # Redondeo: mover el widget 1 px no debe invalidar el caché
                    l, r = round(float(q.get("l", 0)), 3), round(float(q.get("r", 1)), 3)
                    t, b = round(float(q.get("t", 0)), 3), round(float(q.get("b", 1)), 3)
                    swap = q.get("swap", "0") == "1"
                    if url.path == "/palette":
                        colors = cached(("palette",), lambda: palette(img))
                    elif url.path == "/zones":
                        fn = zones_swap if swap else zones
                        colors = cached(("zones", n, l, r, swap), lambda: fn(img, n, l, r))
                    else:
                        colors = cached(("contrast", n, l, r, t, b),
                                        lambda: contrast_bright(img, n, l, r, t, b))
            except Exception as e:
                log(f"Error al leer colores del wallpaper: {e}")
            return self.send(json.dumps({"colors": colors}).encode(), "application/json")

        self.send(latest)

    def log_message(self, *args):
        pass


threading.Thread(target=cava_loop, daemon=True).start()
threading.Thread(target=rotation_loop, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
