#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse


FIXTURE_DIR = Path(__file__).resolve().parent / "registry"
VALID_MANIFEST = json.loads((FIXTURE_DIR / "200-valid-manifest.json").read_text())
VALID_INDEX = json.loads((FIXTURE_DIR / "200-valid-index.json").read_text())
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
OCI_INDEX = "application/vnd.oci.image.index.v1+json"

ROWS = {
    "exists": (200, VALID_MANIFEST),
    "valid-manifest": (200, VALID_MANIFEST),
    "valid-index": (200, VALID_INDEX),
    "manifest-unknown": (404, {"errors": [{"code": "MANIFEST_UNKNOWN"}]}),
    "name-unknown": (404, {"errors": [{"code": "NAME_UNKNOWN"}]}),
    "unauthorized": (401, {"errors": [{"code": "UNAUTHORIZED"}]}),
    "denied": (403, {"errors": [{"code": "DENIED"}]}),
    "rate-limited": (429, {"errors": [{"code": "TOOMANYREQUESTS"}]}),
    "unavailable": (503, {"errors": [{"code": "UNAVAILABLE"}]}),
    "wrong-code": (404, {"errors": [{"code": "BLOB_UNKNOWN"}]}),
    "two-errors": (404, {"errors": [{"code": "MANIFEST_UNKNOWN"}, {"code": "NAME_UNKNOWN"}]}),
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        parts = unquote(urlparse(self.path).path).strip("/").split("/")
        scenario = parts[-3] if len(parts) >= 4 else parts[-1]
        if scenario == "malformed-chunk":
            self.send_response(200)
            self.send_header("Content-Type", OCI_INDEX)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"ZZ\r\n{}\r\n0\r\n\r\n")
            self.wfile.flush()
            self.close_connection = True
            return
        if scenario == "redirect":
            body = b"redirect"
            self.send_response(301)
            self.send_header("Location", "/v2/valid-index/manifests/latest")
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        fixture_bodies = {
            "200-empty": (FIXTURE_DIR / "200-empty.body").read_bytes(),
            "200-html": (FIXTURE_DIR / "200-html.body").read_bytes(),
            "200-malformed-json": (FIXTURE_DIR / "200-malformed-json.body").read_bytes(),
            "200-error-envelope": (FIXTURE_DIR / "200-error-envelope.json").read_bytes(),
            "200-wrong-media-type": (FIXTURE_DIR / "200-wrong-media-type.json").read_bytes(),
            "schema-version-1": (FIXTURE_DIR / "200-schema-version-1.json").read_bytes(),
        }
        if scenario in fixture_bodies:
            status, body = 200, fixture_bodies[scenario]
            content_type = OCI_MANIFEST
        elif scenario in {
            "text-plain", "missing-content-type", "duplicate-content-type",
            "malformed-content-type", "conflicting-content-type",
        }:
            status = 200
            body = json.dumps(VALID_INDEX, separators=(",", ":")).encode()
            content_type = {
                "text-plain": "text/plain",
                "missing-content-type": None,
                "duplicate-content-type": OCI_INDEX,
                "malformed-content-type": f"{OCI_INDEX}; boundary",
                "conflicting-content-type": OCI_MANIFEST,
            }[scenario]
        elif scenario == "malformed-json":
            status, body = 404, b"{"
            content_type = "application/json"
        else:
            status, value = ROWS.get(scenario, (500, {"errors": [{"code": "UNKNOWN"}]}))
            body = json.dumps(value, separators=(",", ":")).encode()
            if status == 200:
                content_type = value["mediaType"]
            else:
                content_type = "application/json"
        self.send_response(status)
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        if scenario == "duplicate-content-type":
            self.send_header("Content-Type", OCI_INDEX)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=5001)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
