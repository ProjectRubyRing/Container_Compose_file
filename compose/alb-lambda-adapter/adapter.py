# =============================================================================
# alb-lambda-adapter — ALB の「Lambda ターゲット統合」のローカル代替
# ---------------------------------------------------------------------------
# 実 AWS では ALB が Lambda をターゲットに持つと、ALB 自身が
#   HTTP リクエスト → ELB イベント JSON に変換 → Lambda を invoke →
#   Lambda の応答 JSON ({statusCode, headers, body, ...}) → HTTP レスポンスに変換
# を内部で行う。ローカルの Lambda ランタイム (RIE) はこの変換をしないため、
# このアダプタが nginx(ALB) と maintenance-lambda(RIE) の間に入って肩代わりする:
#
#   nginx(/maintenance/*) ──HTTP──▶ このアダプタ ──invoke──▶ maintenance-lambda(RIE)
#                         ◀─HTTP──               ◀─JSON──
#
# 依存: 標準ライブラリのみ (http.server / urllib)。pip install 不要。
# =============================================================================
import os
import json
import base64
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LAMBDA_INVOKE_URL = os.environ.get(
    "LAMBDA_INVOKE_URL",
    "http://maintenance-lambda:8080/2015-03-31/functions/function/invocations",
)
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
TARGET_GROUP_ARN = os.environ.get(
    "TARGET_GROUP_ARN",
    "arn:aws:elasticloadbalancing:ap-northeast-1:000000000000:targetgroup/maintenance/0000000000000000",
)
INVOKE_TIMEOUT = float(os.environ.get("INVOKE_TIMEOUT_SECONDS", "30"))


def _build_elb_event(handler: "Handler", body_bytes: bytes) -> dict:
    """HTTP リクエストを ELB ターゲットグループの Lambda イベントに変換する。"""
    parsed = urlparse(handler.path)
    qs = {k: v[-1] for k, v in parse_qs(parsed.query).items()}
    headers = {k.lower(): v for k, v in handler.headers.items()}

    is_b64 = False
    try:
        body = body_bytes.decode("utf-8")
    except UnicodeDecodeError:
        body = base64.b64encode(body_bytes).decode("ascii")
        is_b64 = True

    return {
        "requestContext": {"elb": {"targetGroupArn": TARGET_GROUP_ARN}},
        "httpMethod": handler.command,
        "path": parsed.path,
        "queryStringParameters": qs,
        "headers": headers,
        "body": body,
        "isBase64Encoded": is_b64,
    }


def _invoke_lambda(event: dict) -> dict:
    data = json.dumps(event).encode("utf-8")
    req = urllib.request.Request(
        LAMBDA_INVOKE_URL, data=data, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=INVOKE_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body_bytes = self.rfile.read(length) if length else b""
        event = _build_elb_event(self, body_bytes)

        try:
            resp = _invoke_lambda(event)
        except Exception as e:
            msg = f"alb-lambda-adapter: invoke failed: {type(e).__name__}: {e}".encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(msg)
            return

        status = int(resp.get("statusCode", 200))
        headers = resp.get("headers", {}) or {}
        body = resp.get("body", "") or ""
        body_out = base64.b64decode(body) if resp.get("isBase64Encoded") else body.encode("utf-8")

        self.send_response(status)
        for k, v in headers.items():
            if k.lower() == "content-length":
                continue  # 自前で計算して付与する
            self.send_header(k, str(v))
        self.send_header("Content-Length", str(len(body_out)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body_out)

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_PATCH = _handle
    do_HEAD = _handle

    def log_message(self, fmt, *args):
        print("[alb-lambda-adapter] " + (fmt % args), flush=True)


if __name__ == "__main__":
    print(f"[alb-lambda-adapter] listening :{LISTEN_PORT} -> {LAMBDA_INVOKE_URL}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
