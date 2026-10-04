"""Puente entre cava y el widget Cava Viz.

Endpoints (solo 127.0.0.1):
  /                                   último frame de cava ("12;45;80;...")
  /pause, /resume                     congela / reanuda cava (pantalla completa)
  /bars?n=N&ch=stereo|mono            cambia barras y canales, y reinicia cava
  (si cava está en pausa por pantalla completa o bloqueo, "/" responde "P")
  /palette?cid=&aspect=               colores vivos del wallpaper (JSON)
  /zones?n=&l=&r=&swap=&aspect=&cid=  un color por barra según la columna del wallpaper;
                                      swap=1 intercambia esos colores (JSON)
  /contrast?n=&l=&r=&t=&b=&swap=&...  mismo tono que lo que hay detrás, brillo invertido;
                                      swap=1 además intercambia esos colores (JSON)
  /auto?n=&l=&r=&t=&b=&swap=&...      EXPERIMENTAL: color de su zona, ajustado hasta que se distinga
                                      del fondo detrás del widget (contrast ratio WCAG >= 3:1) (JSON)
  /rotation?enabled=&dir=&seconds=&order=    config de la rotación (la manda el widget)
  /next                               cambia al siguiente wallpaper
"""
import colorsys
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
IMG_EXT = (".jpg", ".jpeg", ".png", ".webp")
PORT = 8765

ORDER_RANDOM, ORDER_ALPHA, ORDER_NEWEST = 0, 1, 2

latest = b"0"
proc = None
pause_reasons = set()             # "fullscreen" y/o "lock": mientras haya alguna, cava está congelado
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


# ---------------- cava ----------------

def write_runtime_conf():
    # Copia raw.conf cambiando solo "bars" y "channels". Tu raw.conf original no se modifica.
    text = open(CONF).read()
    text = re.sub(r"(?m)^\s*bars\s*=.*$", f"bars = {bars}", text)
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


def set_audio(n, ch):
    global bars, channels
    n = max(16, min(300, n))
    n -= n % 2  # en stereo cava reparte mitad y mitad
    ch = ch if ch in ("stereo", "mono") else channels
    if n == bars and ch == channels:
        return
    bars, channels = n, ch
    log(f"cava: {bars} barras, {channels}")
    signal_cava(signal.SIGCONT)  # un proceso congelado no procesa SIGTERM
    signal_cava(signal.SIGTERM)  # cava_loop lo relanza con la config nueva


def update_pause():
    # Una sola función decide: si queda alguna razón de pausa, cava se congela
    signal_cava(signal.SIGSTOP if pause_reasons else signal.SIGCONT)


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
            update_pause()
            log("Pantalla bloqueada: cava en pausa" if locked else "Pantalla desbloqueada: cava activo")
            was_locked = locked
        time.sleep(2)


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
        hh, s, v0 = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        s *= min(1.0, v0 / 0.3)  # en fondos casi negros el tono es ruido: gris oscuro -> barras blancas, no crema
        if s < 0.12:
            s = 0.0  # fondo prácticamente gris: barras grises/blancas puras
        # Fondo oscuro -> barra clara; fondo claro -> barra oscura (transición suave entre 0.4 y 0.6)
        t = min(1.0, max(0.0, (lum - 0.4) / 0.2))
        v = 0.95 * (1 - t) + 0.2 * t
        rr, gg, bb = colorsys.hsv_to_rgb(hh, min(1.0, s * 1.15), v)
        cols.append((round(rr * 255), round(gg * 255), round(bb * 255)))
    return smooth(cols)


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


# ---------------- modo automático (experimental) ----------------

MIN_CONTRAST = 3.0  # WCAG 2.x pide 3:1 como mínimo para elementos gráficos


def rel_luminance(rgb):
    # Luminancia relativa de WCAG: corrige la curva gamma de sRGB antes de ponderar los canales
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a, b):
    la, lb = rel_luminance(a), rel_luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def ensure_contrast(color, bg, target=MIN_CONTRAST):
    """Oscurece o aclara el color, conservando el tono, hasta que se distinga del fondo."""
    if contrast_ratio(color, bg) >= target:
        return list(color)
    h, s, v = colorsys.rgb_to_hsv(*(c / 255 for c in color))

    def with_v(val):
        r, g, b = colorsys.hsv_to_rgb(h, s, val)
        return [round(r * 255), round(g * 255), round(b * 255)]

    def search(make, lo, hi, want_low):
        # Búsqueda binaria del cambio mínimo que alcanza el contraste
        for _ in range(16):
            mid = (lo + hi) / 2
            ok = contrast_ratio(make(mid), bg) >= target
            if ok == want_low:
                lo = mid
            else:
                hi = mid
        return make(lo if want_low else hi)

    # 0.179 es la luminancia donde blanco y negro contrastan igual: arriba de eso conviene oscurecer
    if rel_luminance(bg) > 0.179:
        # Oscurecer: el v más alto (más parecido al original) que cumpla; en v=0 (negro) siempre cumple
        return search(with_v, 0.0, v, want_low=True)
    # Aclarar: primero subir v; si con v=1 no alcanza (ej. azul oscuro), mezclar hacia blanco
    if contrast_ratio(with_v(1.0), bg) >= target:
        return search(with_v, v, 1.0, want_low=False)
    top = with_v(1.0)

    def toward_white(t):
        return [round(c + (255 - c) * t) for c in top]
    return search(toward_white, 0.0, 1.0, want_low=False)


def auto_colors(img, n, left, right, top, bottom, swap):
    cols = zones(img, n, left, right)          # colores que combinan con la imagen
    if swap:
        cols = swap_colors(cols, img)
    # Fondo real detrás de cada barra (solo el área del widget)
    w, h = img.size
    x0, y0 = int(left * w), int(top * h)
    x1, y1 = max(x0 + 1, int(right * w)), max(y0 + 1, int(bottom * h))
    bg = img.crop((x0, y0, x1, y1)).resize((n, 1), Image.Resampling.BOX).load()
    return [ensure_contrast(cols[i], bg[i, 0]) for i in range(n)]


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
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}

        if url.path == "/pause":
            pause_reasons.add("fullscreen")
            update_pause()
        elif url.path == "/resume":
            pause_reasons.discard("fullscreen")
            update_pause()
        elif url.path == "/bars":
            set_audio(int(q.get("n", bars)), q.get("ch", channels))
        elif url.path == "/next":
            # Sin filtro de tiempo: la rotación aplica un cambio a la vez, así que los clics
            # que lleguen mientras Plasma aplica uno se juntan en un solo "siguiente"
            rotate_now.set()
        elif url.path == "/rotation":
            try:
                update_rotation_settings(q)
            except Exception as e:
                log(f"Config de rotación inválida: {e}")
        elif url.path in ("/palette", "/zones", "/contrast", "/auto"):
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
                        def compute():
                            cols = zones(img, n, l, r)
                            return swap_colors(cols, img) if swap else cols
                        colors = cached(("zones", n, l, r, swap), compute)
                    elif url.path == "/auto":
                        colors = cached(("auto", n, l, r, t, b, swap),
                                        lambda: auto_colors(img, n, l, r, t, b, swap))
                    else:
                        # En contraste no se intercambia: invertir deshace el contraste
                        colors = cached(("contrast", n, l, r, t, b),
                                        lambda: contrast_bright(img, n, l, r, t, b))
            except Exception as e:
                log(f"Error al leer colores del wallpaper: {e}")
            return self.send(json.dumps({"colors": colors}).encode(), "application/json")

        # "P" le avisa al widget que cava está en pausa, para que consulte menos seguido
        self.send(b"P" if pause_reasons else latest)

    def log_message(self, *args):
        pass


threading.Thread(target=cava_loop, daemon=True).start()
threading.Thread(target=rotation_loop, daemon=True).start()
threading.Thread(target=lock_loop, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
