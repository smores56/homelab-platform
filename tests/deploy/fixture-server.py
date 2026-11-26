#!/usr/bin/env python3
"""The GitHub API and the ghcr registry, answering out of a golden fixture.

One fixture document is a request, the world behind it (GitHub, the registry, the
host's own state and denylist) and the outcome today produces. This program turns
the `world` half of one into a loopback server, so a suite replays a document
against the answers it names instead of restating them -- a new case needs a new
fixture, not new server code.

    python3 tests/deploy/fixture-server.py <fixture.json> <port>

Both verifiers' suites run it (tests/deploy/fixtures.bats for the server's,
tests/deploy/edge-verify.bats for the edge's): the parity those two assert is only
worth anything if the two roles were asked the same questions, which is one
implementation of the world rather than two renderings of it.

It answers `/token`, then two routes out of `world.tip`/`world.compare` and the
one tag out of `world.tag`; `world.github_status` stands in for a GitHub refusal
(an exhausted anonymous budget) and `world.tag.found` for an unpublished tag.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIXTURE, PORT = sys.argv[1], int(sys.argv[2])

INDEX_TYPE = "application/vnd.oci.image.index.v1+json"
MANIFEST_TYPE = "application/vnd.oci.image.manifest.v1+json"


def world():
    with open(FIXTURE) as handle:
        return json.load(handle)["world"]


def manifest(image):
    return {
        "schemaVersion": 2,
        "mediaType": MANIFEST_TYPE,
        "config": {
            "mediaType": "application/vnd.oci.image.config.v1+json",
            "digest": image["config"],
            "size": 7,
        },
        "layers": [],
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def _send(self, status, document=None, headers=None):
        body = b"" if document is None else json.dumps(document).encode()
        try:
            self.send_response(status)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            # A client that hung up mid-answer is the verifier's own deadline.
            pass

    def do_GET(self):
        state = world()
        path = self.path.split("?", 1)[0]
        if path == "/token":
            self._send(200, {"token": "anonymous-test-token"})
            return
        if path.startswith("/repos/"):
            if state.get("github_status"):
                self._send(state["github_status"], {"message": "no"})
                return
            if path.endswith("/git/ref/heads/main"):
                repo = path.split("/")[3]
                self._send(200, {"ref": "refs/heads/main", "object": {"sha": state["tip"][repo]}})
                return
            if "/compare/" in path:
                self._send(200, {"status": state["compare"], "ahead_by": 1})
                return
        image = state["tag"]
        if "/manifests/" in path:
            ref = path.rsplit("/", 1)[1]
            digest = image["index_digest"] if image["index"] and ref == image["name"] else image["manifest"]
            if not image["found"] or ref not in (image["name"], image["manifest"], image["index_digest"]):
                self._send(404, {"errors": [{"code": "MANIFEST_UNKNOWN"}]})
                return
            if ref == image["name"] and image["index"]:
                document = {
                    "schemaVersion": 2,
                    "mediaType": INDEX_TYPE,
                    "manifests": [
                        {
                            "mediaType": MANIFEST_TYPE,
                            "digest": image["arm64"],
                            "platform": {"os": "linux", "architecture": "arm64"},
                        },
                        {
                            "mediaType": MANIFEST_TYPE,
                            "digest": image["manifest"],
                            "platform": {"os": "linux", "architecture": "amd64"},
                        },
                    ],
                }
            else:
                document = manifest(image)
            self._send(
                200,
                document,
                {
                    "Content-Type": INDEX_TYPE if document.get("manifests") else MANIFEST_TYPE,
                    "Docker-Content-Digest": digest,
                },
            )
            return
        if "/blobs/" in path:
            labels = (
                {}
                if image.get("label") is None
                else {"org.opencontainers.image.revision": image["label"]}
            )
            self._send(200, {"architecture": "amd64", "os": "linux", "config": {"Labels": labels}})
            return
        self._send(404, {})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever(poll_interval=0.01)
