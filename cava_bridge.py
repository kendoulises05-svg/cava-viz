import os
import signal
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = os.path.expanduser("~/.config/cava/raw.conf")
PORT = 8765
latest = b"0"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # El widget llama a /pause y /resume según haya fullscreen
        if self.path == "/pause":
            proc.send_signal(signal.SIGSTOP)
        elif self.path == "/resume":
            proc.send_signal(signal.SIGCONT)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(latest)))
        self.end_headers()
        self.wfile.write(latest)

    def log_message(self, *args):
        pass

server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()

proc = subprocess.Popen(["cava", "-p", CONF], stdout=subprocess.PIPE, text=True)
for line in proc.stdout:
    latest = line.strip().encode()
