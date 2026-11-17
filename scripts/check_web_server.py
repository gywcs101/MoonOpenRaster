"""Regression check for mixed cached UI resources after a local restart."""
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from urllib.request import Request, urlopen
from serve_web import WorkbenchHandler, ROOT

server = ThreadingHTTPServer(("127.0.0.1", 0), partial(WorkbenchHandler, directory=str(ROOT / "web")))
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    base = f"http://127.0.0.1:{server.server_port}/"
    for resource in ["index.html", "style.css", "app.js", "core.js", "worker.js", "assets/capitole.ora"]:
        request = Request(base + resource + "?v=cache-regression", headers={"If-Modified-Since": "Wed, 01 Jan 2031 00:00:00 GMT"})
        with urlopen(request, timeout=5) as response:
            assert response.status == 200
            assert response.headers["Cache-Control"] == "no-store, max-age=0"
            assert response.read() == (ROOT / "web" / resource).read_bytes()
    html = (ROOT / "web/index.html").read_text(encoding="utf8")
    assert "design-switch" not in html and 'class="brand-mark"' not in html
    assert "style.css?v=" in html and "app.js?v=" in html
    print("PASS: fresh resource bytes, cache headers, revision URLs and selected studio shell")
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
