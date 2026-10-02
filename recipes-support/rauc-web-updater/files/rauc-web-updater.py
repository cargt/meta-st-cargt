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

PAGE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>RAUC Bundle Installer</title>
<style>
  body { font-family: sans-serif; max-width: 640px; margin: 3em auto; }
  #drop { border: 3px dashed #888; border-radius: 8px; padding: 3em;
          text-align: center; color: #555; }
  #drop.over { border-color: #2a7; color: #2a7; }
  pre { background: #111; color: #ddd; padding: 1em; overflow-x: auto;
        white-space: pre-wrap; }
  .ok { color: #2a7; font-weight: bold; }
  .fail { color: #c33; font-weight: bold; }
</style>
</head>
<body>
<h1>RAUC Bundle Installer</h1>
<div id="drop">Drop a .raucb file here, or click to browse</div>
<input type="file" id="file" accept=".raucb" style="display:none">
<div id="status"></div>
<pre id="log" style="display:none"></pre>
<script>
const drop = document.getElementById('drop');
const fileInput = document.getElementById('file');
const status = document.getElementById('status');
const log = document.getElementById('log');

drop.addEventListener('click', () => fileInput.click());
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

function upload(file) {
  drop.textContent = 'Installing ' + file.name + ' - this can take a few minutes...';
  log.style.display = 'none';
  status.textContent = '';
  const form = new FormData();
  form.append('bundle', file);
  fetch('/upload', { method: 'POST', body: form })
    .then(r => r.json())
    .then(data => {
      drop.textContent = 'Drop a .raucb file here, or click to browse';
      status.innerHTML = data.ok
        ? '<span class="ok">Install succeeded.</span> Reboot to switch to the new slot: <a href="/reboot">Reboot now</a>'
        : '<span class="fail">Install failed.</span>';
      log.textContent = data.log;
      log.style.display = 'block';
    })
    .catch(err => {
      drop.textContent = 'Drop a .raucb file here, or click to browse';
      status.innerHTML = '<span class="fail">Upload failed: ' + err + '</span>';
    });
}
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        if self.path == "/reboot":
            self._send_html("<p>Rebooting now.</p>")
            subprocess.Popen(["reboot"])
            return
        if self.path == "/":
            self._send_html(PAGE)
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
