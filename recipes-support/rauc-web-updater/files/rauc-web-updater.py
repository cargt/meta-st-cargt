#!/usr/bin/env python3
"""
Minimal drag-and-drop RAUC bundle installer.

Serves a single page with a file-drop zone on BIND_PORT. Dropping (or
browsing to) a .raucb file uploads it, runs `rauc install` against it
synchronously, and shows the install log plus a "Reboot now" link on
success - RAUC installs don't take effect until the next reboot, and this
deliberately doesn't reboot on its own so whoever just dropped a test
bundle gets to see the result first.

No auth, no HTTPS: this is a lab/dev convenience for pushing a single
bundle to a single already-on-the-bench board (see cargt-image-dev.bb -
same dev-image-only placement as rauc-hawkbit-updater), not something to
expose off a trusted lab network. It also only ever has one real
"client" at a time by construction (someone standing at a browser
pointed at this one board), so no auth/locking was worth the complexity.
"""

import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND_PORT = 8080
BUNDLE_DIR = "/usr/local/rauc-web-updater"
BUNDLE_PATH = os.path.join(BUNDLE_DIR, "bundle.raucb")

# Cargt branding (stylesheet, theme script, logo, favicon, font), installed
# by the recipe. Only these names are served, so a request can't walk out
# of the directory.
STATIC_DIR = "/usr/share/rauc-web-updater"
STATIC_FILES = {
    "cargt.css": "text/css; charset=utf-8",
    "cargt-theme.js": "text/javascript; charset=utf-8",
    "cargt-logo.svg": "image/svg+xml",
    "favicon.png": "image/png",
    "Manrope-Variable.woff2": "font/woff2",
}

UPLOAD_ICON = (
    '<svg class="icon-upload" viewBox="0 0 24 24" aria-hidden="true">'
    '<path d="M12 3l5 5h-3v6h-4V8H7l5-5zM5 17h14v3H5z"/></svg>'
)

# Head and navbar shared by the page and the reboot notice. The theme
# script comes before the stylesheet so the page never flashes light.
HEADER = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cargt Software Update</title>
<link rel="icon" type="image/png" href="/static/favicon.png">
<script src="/static/cargt-theme.js"></script>
<link rel="stylesheet" href="/static/cargt.css">
</head>
<body>
<nav class="cargt-nav">
  <div class="container">
    <a class="brand" href="/"><img src="/static/cargt-logo.svg" alt="Cargt"></a>
    <button id="cargt-theme-toggle" type="button" title="Switch between light and dark"
            aria-label="Switch between light and dark theme">
      <svg class="icon-sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.5"/><path d="M12 1.5v3M12 19.5v3M1.5 12h3M19.5 12h3M4.6 4.6l2.1 2.1M17.3 17.3l2.1 2.1M4.6 19.4l2.1-2.1M17.3 6.7l2.1-2.1" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>
      <svg class="icon-moon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z"/></svg>
    </button>
  </div>
</nav>
<main class="container">
"""

FOOTER = """</main>
<footer class="cargt-footer container">Cargt · Modern electronics. Confidence at every step.</footer>
</body>
</html>
"""

PAGE = HEADER + """<h1>Software Update</h1>
<p class="lead">Install a new software image on this device.</p>
<p>Upload a .raucb bundle below. RAUC installs it to the inactive slot; reboot afterwards to run it.</p>
<section class="card">
<h2>Install an update</h2>
<div id="drop" role="button" tabindex="0">
  <span id="drop-text">""" + UPLOAD_ICON + """Drop a .raucb file here, or click to choose one.<small>The install starts as soon as you drop the file.</small></span>
</div>
<input type="file" id="file" accept=".raucb" hidden>
<div id="status"></div>
</section>
<section class="card" id="log-card" hidden>
<h2>Install log</h2>
<pre id="log"></pre>
</section>
<script>
const drop = document.getElementById('drop');
const dropText = document.getElementById('drop-text');
const idleText = dropText.innerHTML;
const fileInput = document.getElementById('file');
const status = document.getElementById('status');
const log = document.getElementById('log');
const logCard = document.getElementById('log-card');

drop.addEventListener('click', () => fileInput.click());
drop.addEventListener('keydown', e => {
  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fileInput.click(); }
});
drop.addEventListener('dragover', e => { e.preventDefault(); drop.classList.add('over'); });
drop.addEventListener('dragleave', () => drop.classList.remove('over'));
drop.addEventListener('drop', e => {
  e.preventDefault();
  drop.classList.remove('over');
  if (e.dataTransfer.files.length) upload(e.dataTransfer.files[0]);
});
fileInput.addEventListener('change', () => {
  if (fileInput.files.length) upload(fileInput.files[0]);
});

function idle() {
  drop.classList.remove('busy');
  dropText.innerHTML = idleText;
}

function upload(file) {
  drop.classList.add('busy');
  dropText.innerHTML = '<span class="spinner"></span>';
  dropText.append('Installing ' + file.name + ' - this can take a few minutes...');
  logCard.hidden = true;
  status.textContent = '';
  const form = new FormData();
  form.append('bundle', file);
  fetch('/upload', { method: 'POST', body: form })
    .then(r => r.json())
    .then(data => {
      idle();
      status.innerHTML = data.ok
        ? '<div class="alert ok"><strong>Install succeeded.</strong> Reboot to switch to the new slot. <a class="btn" href="/reboot">Reboot now</a></div>'
        : '<div class="alert fail"><strong>Install failed.</strong> See the install log below.</div>';
      log.textContent = data.log;
      logCard.hidden = false;
    })
    .catch(err => {
      idle();
      status.innerHTML = '<div class="alert fail"><strong>Upload failed:</strong> </div>';
      status.firstChild.append(String(err));
    });
}
</script>
""" + FOOTER

REBOOT_PAGE = HEADER + """<h1>Rebooting</h1>
<p class="lead">The device is restarting into the new slot.</p>
<p>This page can be reloaded once the device is back on the network.</p>
""" + FOOTER


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        if self.path == "/reboot":
            self._send_html(REBOOT_PAGE)
            subprocess.Popen(["reboot"])
            return
        if self.path == "/":
            self._send_html(PAGE)
            return
        if self.path.startswith("/static/"):
            self._send_static(self.path[len("/static/"):])
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/upload":
            self.send_error(404)
            return

        content_type = self.headers["Content-Type"] or ""
        if "multipart/form-data" not in content_type or "boundary=" not in content_type:
            self._send_json({"ok": False, "log": "Expected a multipart/form-data upload."})
            return
        boundary = content_type.split("boundary=", 1)[1].encode()

        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)

        file_bytes = self._extract_file_part(body, boundary)
        if file_bytes is None:
            self._send_json({"ok": False, "log": "No file in upload."})
            return

        os.makedirs(BUNDLE_DIR, exist_ok=True)
        with open(BUNDLE_PATH, "wb") as f:
            f.write(file_bytes)

        result = subprocess.run(
            ["rauc", "install", BUNDLE_PATH],
            capture_output=True, text=True,
        )
        ok = result.returncode == 0
        self._send_json({"ok": ok, "log": result.stdout + result.stderr})

    def _send_html(self, body):
        encoded = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _send_static(self, name):
        content_type = STATIC_FILES.get(name)
        if content_type is None:
            self.send_error(404)
            return
        try:
            with open(os.path.join(STATIC_DIR, name), "rb") as f:
                data = f.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=3600")
        self.end_headers()
        self.wfile.write(data)

    @staticmethod
    def _extract_file_part(body, boundary):
        """
        Pull the "bundle" field's raw bytes out of a multipart/form-data
        body. Deliberately not using the stdlib `cgi` module here - it's
        deprecated since 3.11 and removed outright in 3.13, and this is the
        one place in the whole image that would've used it.

        Good enough for this form's one fixed field (the page's own JS
        always sends exactly one `bundle` file part, nothing else) - not a
        general-purpose multipart parser.
        """
        marker = b"--" + boundary
        for part in body.split(marker):
            if b'name="bundle"' not in part:
                continue
            headers, _, content = part.partition(b"\r\n\r\n")
            if not content:
                continue
            # Strip the trailing \r\n before the next boundary marker.
            return content[:-2] if content.endswith(b"\r\n") else content
        return None

    def _send_json(self, obj):
        encoded = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", BIND_PORT), Handler).serve_forever()
