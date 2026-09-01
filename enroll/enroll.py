#!/usr/bin/env python3
"""Minimal device-enrollment service (Python 3 stdlib only).

ESP32 IoT devices present a reusable factory client certificate over mutual TLS,
POST a PKCS#10 CSR (the device keeps its own private key — this service never
sees one), and receive back a per-device certificate issued by EJBCA's
ManagementCA.

Endpoints
  GET  /health  -> 200 "ok"            (no client cert required; used by compose healthcheck)
  POST /enroll  -> 200 + PEM certificate
               -> 403  no client certificate presented
               -> 400  bad JSON / bad device_id / malformed CSR (or EJBCA rejects the CSR)
               -> 502  EJBCA unreachable or failed

Configuration comes from environment variables (never hardcoded):
  EJBCA_API_URL        base URL of the EJBCA REST API, e.g. https://ejbca:8443/ejbca/ejbca-rest-api
  EJBCA_CLIENT_CERT    admin client cert (PEM) used to authenticate to EJBCA (mTLS)
  EJBCA_CLIENT_KEY     matching admin client key (PEM)
  EJBCA_CA_NAME        CA that issues device certs (default ManagementCA)
  EJBCA_CERT_PROFILE   certificate profile (default ENDUSER)
  EJBCA_EE_PROFILE     end entity profile (default EMPTY)
  EJBCA_EE_PASSWORD    enrollment code for the (auto-created) end entity (default changeit)
  SERVER_CERT          this service's TLS server cert (PEM, CN=enroll)
  SERVER_KEY           this service's TLS server key (PEM)
  CA_BUNDLE            CA bundle used to trust device client certs AND the EJBCA server
  LISTEN_PORT          listen port (default 9443)
"""

import base64
import datetime
import json
import logging
import os
import re
import ssl
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --- configuration (from the environment) -----------------------------------------------
EJBCA_API_URL     = os.environ.get("EJBCA_API_URL", "https://ejbca:8443/ejbca/ejbca-rest-api")
EJBCA_CLIENT_CERT = os.environ["EJBCA_CLIENT_CERT"]
EJBCA_CLIENT_KEY  = os.environ["EJBCA_CLIENT_KEY"]
EJBCA_CA_NAME     = os.environ.get("EJBCA_CA_NAME", "ManagementCA")
EJBCA_CERT_PROFILE = os.environ.get("EJBCA_CERT_PROFILE", "ENDUSER")
EJBCA_EE_PROFILE  = os.environ.get("EJBCA_EE_PROFILE", "EMPTY")
EJBCA_EE_PASSWORD = os.environ.get("EJBCA_EE_PASSWORD", "changeit")
SERVER_CERT       = os.environ["SERVER_CERT"]
SERVER_KEY        = os.environ["SERVER_KEY"]
CA_BUNDLE         = os.environ["CA_BUNDLE"]
LISTEN_PORT       = int(os.environ.get("LISTEN_PORT", "9443"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("enroll")

_DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


class EjbcaError(Exception):
    """Raised when the forward to EJBCA fails. is_client_error -> 400, else 502."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message
        self.is_client_error = 400 <= status < 500 and status != 403


def validate_csr(csr):
    """Cheap local sanity check; EJBCA does the real ASN.1 parsing."""
    if "-----BEGIN CERTIFICATE REQUEST-----" not in csr:
        return False
    if "-----END CERTIFICATE REQUEST-----" not in csr:
        return False
    try:
        body = csr.split("-----BEGIN CERTIFICATE REQUEST-----", 1)[1].split("-----END CERTIFICATE REQUEST-----", 1)[0]
        base64.b64decode("".join(body.split()), validate=True)
        return True
    except Exception:
        return False


def sanitize_device_id(device_id):
    device_id = device_id.strip()
    return device_id if _DEVICE_ID_RE.match(device_id) else None


def pem_cert_from_der(b64der):
    """Wrap the base64 DER from EJBCA into a PEM certificate (RFC 7468)."""
    der = base64.b64decode(b64der)
    b64 = base64.b64encode(der).decode("ascii")
    lines = [b64[i:i + 64] for i in range(0, len(b64), 64)]
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(lines) + "\n-----END CERTIFICATE-----\n"


def call_ejbca(csr, username):
    """Forward the CSR to EJBCA's pkcs10enroll endpoint (admin client-cert auth)."""
    url = EJBCA_API_URL.rstrip("/") + "/v1/certificate/pkcs10enroll"
    payload = json.dumps({
        "certificate_request": csr,
        "certificate_profile_name": EJBCA_CERT_PROFILE,
        "end_entity_profile_name": EJBCA_EE_PROFILE,
        "certificate_authority_name": EJBCA_CA_NAME,
        "username": username,
        "password": EJBCA_EE_PASSWORD,
        "response_format": "DER",
    }).encode("utf-8")

    ctx = ssl.create_default_context(cafile=CA_BUNDLE)     # trust EJBCA's server cert
    ctx.load_cert_chain(EJBCA_CLIENT_CERT, EJBCA_CLIENT_KEY)  # authenticate as admin

    req = urllib.request.Request(
        url, data=payload, method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        raise EjbcaError(status=e.code, message=body) from e
    except (urllib.error.URLError, ssl.SSLError, OSError) as e:
        raise EjbcaError(status=0, message=str(e)) from e


class Handler(BaseHTTPRequestHandler):
    server_version = "enroll/1.0"

    def _send(self, code, body, content_type="text/plain"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            self._send(200, "ok\n")
        else:
            self._send(404, "not found\n")

    def do_POST(self):
        if self.path.rstrip("/") != "/enroll":
            self._send(404, "not found\n")
            return

        # mTLS: the TLS layer verified the client cert chains to ManagementCA
        # (CERT_OPTIONAL). /health stays cert-free, so enforce here for /enroll.
        if not self.connection.getpeercert():
            logger.warning("enroll rejected: no client certificate presented")
            self._send(403, "client certificate required\n")
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length > 0 else b""
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, json.JSONDecodeError):
            self._send(400, "invalid JSON body\n")
            return

        device_id = body.get("device_id", "")
        csr = body.get("csr", "")
        if not isinstance(device_id, str) or not device_id.strip():
            self._send(400, "missing device_id\n")
            return
        device_id = sanitize_device_id(device_id)
        if device_id is None:
            self._send(400, "invalid device_id (allowed: A-Z a-z 0-9 . _ - , max 64)\n")
            return
        if not isinstance(csr, str) or not validate_csr(csr):
            self._send(400, "invalid CSR (expected PEM PKCS#10 request)\n")
            return

        # Forward to EJBCA and map its outcome to our contract.
        try:
            resp = call_ejbca(csr, device_id)
        except EjbcaError as e:
            if e.is_client_error:
                logger.warning("EJBCA rejected CSR for device '%s': %s", device_id, e.message[:200])
                self._send(400, "EJBCA rejected the CSR: %s\n" % e.message[:200])
            else:
                logger.error("EJBCA failure for device '%s' (status %s): %s",
                             device_id, e.status, e.message[:200])
                self._send(502, "EJBCA enrollment failed\n")
            return
        except Exception as e:  # pragma: no cover - defensive
            logger.error("unexpected error for device '%s': %s", device_id, e)
            self._send(502, "EJBCA unreachable\n")
            return

        pem = pem_cert_from_der(resp["certificate"])
        serial = str(resp.get("serial_number", "?"))
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat()

        # Enrollment record to stdout (docker logs) — device_id, serial, timestamp.
        print(json.dumps({"event": "enroll", "device_id": device_id,
                          "serial_number": serial, "timestamp": ts}), flush=True)
        logger.info("issued cert for device '%s' serial=%s", device_id, serial)

        self._send(200, pem, "application/x-pem-file")


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(SERVER_CERT, SERVER_KEY)
    ctx.load_verify_locations(cafile=CA_BUNDLE)
    # CERT_OPTIONAL so GET /health needs no client cert; POST /enroll enforces
    # the requirement in the handler (invalid client certs fail the handshake).
    ctx.verify_mode = ssl.CERT_OPTIONAL

    httpd = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    logger.info("enroll listening on %s (EJBCA: %s)", LISTEN_PORT, EJBCA_API_URL)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
