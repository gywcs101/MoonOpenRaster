"""Build and serve the workbench with fresh local resources on every reload."""
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial
import argparse
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

class WorkbenchHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def send_head(self):
        # Revalidate the bytes even if an earlier generic server cached this URL.
        for header in ["If-Modified-Since", "If-None-Match"]:
            if header in self.headers:
                del self.headers[header]
        return super().send_head()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-build", action="store_true", help="Serve the existing compiled workbench")
    args = parser.parse_args()
    if not args.no_build:
        subprocess.run([sys.executable, str(ROOT / "scripts/build_web.py")], cwd=ROOT, check=True)
    if not (ROOT / "web/core.js").is_file():
        parser.error("web/core.js is missing. Run without --no-build to compile it.")
    handler = partial(WorkbenchHandler, directory=str(ROOT / "web"))
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    except OSError as error:
        parser.exit(1, f"Cannot open port {args.port}: {error}. Stop the previous server or select --port 8766.\n")
    print(f"MoonOpenRaster: http://127.0.0.1:{args.port}/", flush=True)
    print("Press Ctrl+C to stop. Browser caching is disabled.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    main()
