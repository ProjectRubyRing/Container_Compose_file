#!/usr/bin/env python3
# =============================================================================
# frontend 向け ALB (HTTPS リスナー → HTTP ターゲットグループ) の偽装 (alb-front)
# -----------------------------------------------------------------------------
# 実 AWS:
#   ブラウザ ──HTTPS──▶ ALB :443 (ACM 証明書で TLS 終端)
#                         └──HTTP──▶ ターゲットグループ (ECS app-front:8080 / JBoss EAP)
#
#   ALB はターゲットへの要求に次のヘッダを付ける:
#     X-Forwarded-For   … クライアント IP を末尾へ追記 (xff_header_processing.mode=append 既定)
#     X-Forwarded-Proto … クライアントが ALB へ接続したプロトコル (HTTPS リスナーなら https)
#     X-Forwarded-Port  … クライアントが接続したリスナーのポート
#     X-Amzn-Trace-Id   … 無ければ Root=1-<epoch hex 8>-<hex 24> を採番、Root があれば Self を挿入
#   クライアントが送った X-Forwarded-Proto / X-Forwarded-Port は捨てて上書きする。
#   Host はクライアントが送った値をそのまま渡し、X-Forwarded-Host は付けない。
#   ターゲットの応答ヘッダ (★Location を含む★) は書き換えずにそのまま返す。
#   ターゲットへ届かないときは ALB 自身が 502 / 503 / 504 (Server: awselb/2.0) を返す。
#
# このスクリプトはその「HTTPS リスナー → HTTP ターゲット」の転送を再現する
# (既存の alb サービス (nginx) とは別物。あちらは backend / secure-api 向け)。
# 目的は「ALB → JBoss EAP が HTTP でも、リダイレクトの Location が https で返るか
# (JBoss EAP が X-Forwarded-Proto を反映しているか)」を区間ごとに確認すること。
#
# 実 ALB と違う点 (ローカル都合):
#   - ターゲットは IP ではなく compose サービス名 (ALB_FRONT_TARGET) で 1 つだけ
#   - リスナーのポートはホストへ公開するポートと同じ番号にする (既定 8443)。
#     X-Forwarded-Port と、クライアントが実際に使ったポートを一致させるため
#   - ターゲットへの接続は要求ごとに張る (ALB は keep-alive で使い回す)
#   - HTTP/2 は扱わない (ALPN は http/1.1 のみ)
#
# 【使い方】
#   常駐 (compose の command):
#     python3 alb-front.py serve
#   コンテナ内から実行 (docker exec / docker compose exec alb-front ...):
#     python3 alb-front.py report                  # 既定 API で Location ヘッダ確認レポート
#     python3 alb-front.py report /iwinmichl/xxx   # 指定した API で確認
#     python3 alb-front.py exchanges --limit 5     # 直近の転送記録 (JSON)
#     python3 alb-front.py default-path            # 既定の確認 API (ALB_FRONT_CHECK_PATH)
#     python3 alb-front.py config                  # リスナー / ターゲットの設定 (JSON)
#     python3 alb-front.py ready                   # 自身の生存確認 (compose healthcheck 用)
#
#   report の終了コード:
#     0 = OK       (Location が https で返り、X-Forwarded-Proto が連携されている)
#     1 = NG       (Location が http で返った / X-Forwarded-Proto が連携されていない)
#     2 = 実行不能 (偽装 ALB が応答しない・ターゲットへ届かない 502/503/504 など)
#     3 = 判定保留 (リダイレクトが返らなかった。API のパス違い・未デプロイなど)
#
# 【HTTP API】(管理用。既定 :8081。ホストへは compose の ports で公開する)
#   GET /healthz            … 生存確認
#   GET /config             … リスナー / ターゲットの設定
#   GET /exchanges          … 直近の転送記録 (新しい順)
#   GET /exchanges/<Root>   … X-Amzn-Trace-Id の Root (1-xxxxxxxx-...) で 1 件引く
#
# 標準ライブラリだけで動く (python:3.12-slim をそのまま使う)。
# =============================================================================
from __future__ import annotations

import argparse
import collections
import hashlib
import http.client
import json
import os
import secrets
import signal
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urljoin, urlsplit

DISPLAY_TZ = timezone(timedelta(hours=9), "JST")

# 転送しないヘッダ (hop-by-hop)。ALB も接続単位のヘッダはターゲットへ渡さない。
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "proxy-connection", "te", "trailer", "trailers", "transfer-encoding", "upgrade",
}
# ALB が自分の値で上書きする (クライアントが送ってきた値は捨てる) ヘッダ
ALB_OVERWRITES = {"x-forwarded-proto", "x-forwarded-port"}
# 転送記録 (/exchanges) に値を残さないヘッダ
SENSITIVE_HEADERS = {"authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"}

# dhapp の /api/redirect-check/redirect が 302 に載せる診断ヘッダ
DIAG_PREFIX = "x-redirect-check-"

# ALB 自身が返すエラー応答 (実 ALB と同じ本文・Server ヘッダ)
ALB_SERVER_HEADER = "awselb/2.0"
ALB_ERROR_REASONS = {
    400: "Bad Request",
    502: "Bad Gateway",
    503: "Service Temporarily Unavailable",
    504: "Gateway Time-out",
}

CLI_OK = 0
CLI_NG = 1
CLI_UNAVAILABLE = 2
CLI_PENDING = 3

CHECK_USER_AGENT = "alb-front-location-check/1.0"
BODY_PREVIEW_BYTES = 4096


def configure_stdio() -> None:
    """日本語と罫線を含むレポートを、ロケール既定の文字コードに関係なく出力する。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", newline="\n")
        except Exception:
            pass


def iso_time(epoch: float | None = None) -> str:
    return datetime.fromtimestamp(epoch or time.time(), DISPLAY_TZ).isoformat(timespec="milliseconds")


def display_time(epoch: float | None = None) -> str:
    return datetime.fromtimestamp(epoch or time.time(), DISPLAY_TZ).strftime("%Y-%m-%d %H:%M:%S %Z")


def log(message: str) -> None:
    """docker compose logs alb-front で読む 1 行ログ (ALB のアクセスログ相当)。"""
    print(f"{iso_time()} [alb-front] {message}", flush=True)


# --- 設定 ----------------------------------------------------------------------
class Config:
    """環境変数から読む設定 (serve と CLI で同じ値を使う)。"""

    def __init__(self) -> None:
        env = os.environ
        self.https_port = int(env.get("ALB_FRONT_HTTPS_PORT") or 8443)
        self.admin_port = int(env.get("ALB_FRONT_ADMIN_PORT") or 8081)
        self.target = (env.get("ALB_FRONT_TARGET") or "http://frontend:8080").rstrip("/")
        parts = urlsplit(self.target)
        if parts.scheme != "http" or not parts.hostname or parts.path not in ("", "/"):
            raise ValueError(
                f"ALB_FRONT_TARGET は http://<ホスト>:<ポート> で指定します "
                f"(ターゲットグループのプロトコル = HTTP): {self.target}"
            )
        self.target_host = parts.hostname
        self.target_port = parts.port or 80
        self.cert = env.get("ALB_FRONT_TLS_CERT") or "/pki/alb/ca-issued/fullchain.crt"
        self.key = env.get("ALB_FRONT_TLS_KEY") or "/pki/alb/ca-issued/server.key"
        self.ca_bundle = env.get("ALB_FRONT_CA_BUNDLE") or "/pki/ca/verify-bundle.crt"
        # report がクライアント役として名乗るホスト名 (Host / SNI)。証明書の SAN に含まれること
        self.check_host = env.get("ALB_FRONT_CHECK_HOST") or "localhost"
        self.check_path = env.get("ALB_FRONT_CHECK_PATH") or "/iwinmichl/api/redirect-check/redirect"
        # ALB のターゲット接続タイムアウト (10 秒固定) とアイドルタイムアウト (既定 60 秒)
        self.connect_timeout = float(env.get("ALB_FRONT_CONNECT_TIMEOUT") or 10)
        self.idle_timeout = float(env.get("ALB_FRONT_IDLE_TIMEOUT") or 60)
        self.history_limit = int(env.get("ALB_FRONT_HISTORY_LIMIT") or 200)

    @property
    def client_authority(self) -> str:
        """クライアントが送る Host (既定ポート 443 のときはポートを付けない)。"""
        return self.check_host if self.https_port == 443 else f"{self.check_host}:{self.https_port}"

    def snapshot(self) -> dict:
        return {
            "listener": {"protocol": "HTTPS", "port": self.https_port,
                         "certificate": self.cert, "ssl_policy": "TLSv1.2 / TLSv1.3"},
            "target_group": {"protocol": "HTTP", "target": self.target},
            "forwarded_headers": {
                "X-Forwarded-For": "append (クライアント IP を末尾へ追記)",
                "X-Forwarded-Proto": "https (クライアントの値は上書き)",
                "X-Forwarded-Port": f"{self.https_port} (クライアントの値は上書き)",
                "X-Amzn-Trace-Id": "無ければ Root を採番 / Root があれば Self を挿入",
                "Host": "クライアントの値をそのまま渡す (X-Forwarded-Host は付けない)",
            },
            "response": "ターゲットの応答ヘッダ (Location を含む) は書き換えない",
            "connect_timeout_seconds": self.connect_timeout,
            "idle_timeout_seconds": self.idle_timeout,
            "check": {"host": self.check_host, "path": self.check_path},
            "admin_port": self.admin_port,
        }


# --- X-Amzn-Trace-Id ---------------------------------------------------------
def new_trace_value() -> str:
    """ALB と同じ書式 (1-<epoch 秒の 16 進 8 桁>-<16 進 24 桁>)。"""
    return "1-%08x-%s" % (int(time.time()), secrets.token_hex(12))


def apply_trace_header(incoming: str | None) -> tuple[str, str]:
    """ALB と同じ規則で X-Amzn-Trace-Id を組み立て、(ターゲットへ送る値, Root) を返す。

    - 無ければ Root=<新規> を付ける
    - Root があれば Self=<新規> を挿入する (Self があれば値を更新する)
    - それ以外のフィールドはそのまま残す
    """
    if not incoming or not incoming.strip():
        root = new_trace_value()
        return f"Root={root}", root
    root = ""
    others: list[str] = []
    for field in (part.strip() for part in incoming.split(";")):
        if not field:
            continue
        name, _, value = field.partition("=")
        if name.strip().lower() == "root":
            root = value.strip()
        elif name.strip().lower() == "self":
            continue
        else:
            others.append(field)
    if not root:
        root = new_trace_value()
    return ";".join([f"Self={new_trace_value()}", f"Root={root}"] + others), root


def trace_root_of(value: str | None) -> str:
    for field in (value or "").split(";"):
        name, _, root = field.strip().partition("=")
        if name.lower() == "root":
            return root.strip()
    return ""


def redact_headers(headers: list[tuple[str, str]]) -> list[list[str]]:
    return [[name, "(省略)" if name.lower() in SENSITIVE_HEADERS else value] for name, value in headers]


def header_value(headers: list, name: str) -> str | None:
    """[[名前, 値], ...] から名前 (大文字小文字を区別しない) で最初の値を引く。"""
    lower = name.lower()
    for entry in headers or []:
        if entry[0].lower() == lower:
            return entry[1]
    return None


# --- 転送記録 ------------------------------------------------------------------
class ExchangeStore:
    """直近の転送記録 (新しい順に引ける固定長のリングバッファ)。"""

    def __init__(self, limit: int) -> None:
        self.lock = threading.Lock()
        self.items: collections.deque = collections.deque(maxlen=max(limit, 1))

    def add(self, record: dict) -> None:
        with self.lock:
            self.items.append(record)

    def recent(self, limit: int) -> list[dict]:
        with self.lock:
            return list(reversed(self.items))[: max(limit, 1)]

    def find(self, key: str) -> dict | None:
        with self.lock:
            for record in reversed(self.items):
                if key in (record.get("trace_root"), record.get("trace_id")):
                    return record
        return None


# --- HTTPS リスナー --------------------------------------------------------------
def remember_sni(sock, server_name, _context) -> None:
    """クライアントが送った SNI を接続に覚えさせる (レポート・ログ用)。"""
    try:
        sock.alb_front_sni = server_name
    except Exception:
        pass


def build_server_context(config: Config) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    # ELBSecurityPolicy-TLS13-1-2-2021-06 (ALB の既定) と同じく TLS 1.2 以上
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(config.cert, config.key)
    context.set_alpn_protocols(["http/1.1"])
    context.sni_callback = remember_sni
    return context


class TLSThreadingHTTPServer(ThreadingHTTPServer):
    """接続ごとのスレッドで TLS ハンドシェイクする HTTPServer (accept を詰まらせない)。"""

    daemon_threads = True

    def __init__(self, address, handler, context: ssl.SSLContext, config: Config, store: ExchangeStore):
        self.ssl_context = context
        self.config = config
        self.store = store
        super().__init__(address, handler)

    def get_request(self):
        sock, address = self.socket.accept()
        return self.ssl_context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), address

    def handle_error(self, request, client_address) -> None:
        error = sys.exc_info()[1]
        # 接続だけ張って閉じるクライアント (ポート監視など) は記録しない
        if isinstance(error, (ssl.SSLEOFError, ConnectionResetError, BrokenPipeError, TimeoutError)):
            return
        hint = ""
        if isinstance(error, ssl.SSLError) and any(
                marker in str(error).upper() for marker in ("HTTP_REQUEST", "WRONG_VERSION_NUMBER")):
            hint = " ← HTTPS リスナーへ http:// で接続していないか確認"
        log(
            f"listener=https:{self.config.https_port} client={client_address[0]}:{client_address[1]} "
            f"接続を閉じました ({error.__class__.__name__}: {error}){hint}"
        )


class ListenerHandler(BaseHTTPRequestHandler):
    """HTTPS リスナー。受けた要求を ALB と同じ規則でターゲット (HTTP) へ転送する。"""

    protocol_version = "HTTP/1.1"

    def version_string(self) -> str:
        # http.server 自身が返すエラー (501 など) も、ALB が返す応答と同じ Server にする
        return ALB_SERVER_HEADER

    def setup(self) -> None:
        # ハンドシェイクは接続のスレッドで行う。失敗は handle_error へ流れる。
        self.request.settimeout(30)
        self.request.do_handshake()
        self.tls_version = self.request.version()
        cipher = self.request.cipher()
        self.tls_cipher = cipher[0] if cipher else None
        self.tls_sni = getattr(self.request, "alb_front_sni", None)
        self.request.settimeout(self.server.config.idle_timeout)
        super().setup()

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - 基底クラスの API
        if fmt.startswith("Request timed out"):
            return  # keep-alive 接続のアイドル切断 (ALB も黙って閉じる)
        log("listener " + (fmt % args))

    def do_GET(self) -> None:  # noqa: N802 - 基底クラスの API
        self._proxy()

    do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_GET

    # ---- 転送 -------------------------------------------------------------
    def _read_body(self) -> bytes | None:
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            chunks = []
            while True:
                size_line = self.rfile.readline(65537)
                size = int(size_line.split(b";", 1)[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline(65537) not in (b"\r\n", b"\n", b""):
                        pass
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            return b"".join(chunks)
        length = self.headers.get("Content-Length")
        if length:
            size = int(length)
            if size < 0:
                raise ValueError("Content-Length が負です")
            return self.rfile.read(size) if size else b""
        return None

    def _proxy(self) -> None:
        config: Config = self.server.config
        started = time.monotonic()
        received_at = time.time()
        client_ip, client_port = self.client_address[0], self.client_address[1]
        method = self.command
        incoming = list(self.headers.items())

        record = {
            "trace_root": "",
            "trace_id": "",
            "received_at": iso_time(received_at),
            "listener": {"protocol": "HTTPS", "port": config.https_port},
            "client": {"ip": client_ip, "port": client_port},
            "tls": {"version": self.tls_version, "cipher": self.tls_cipher, "sni": self.tls_sni},
            "request": {
                "method": method,
                "path": self.path,
                "http_version": self.request_version,
                "host": self.headers.get("Host"),
                "headers": redact_headers(incoming),
            },
            "target": {
                "group_protocol": "HTTP",
                "url": f"{config.target}{self.path}",
                "peer": None,
                "headers_sent": [],
            },
            "target_response": None,
            "response": None,
            "error": "",
            "duration_ms": 0,
        }

        try:
            body = self._read_body()
        except (ValueError, OSError) as exc:
            record["error"] = f"要求本文を読めません ({exc.__class__.__name__}: {exc})"
            self._alb_error(400, record, started)
            return

        # --- ALB が付与 / 上書きするヘッダ -----------------------------------
        sent: list[tuple[str, str]] = []
        xff_values: list[str] = []
        trace_incoming = None
        for name, value in incoming:
            lower = name.lower()
            if lower in HOP_BY_HOP or lower in ALB_OVERWRITES or lower == "content-length":
                continue
            if lower == "x-forwarded-for":
                xff_values.append(value.strip())
                continue
            if lower == "x-amzn-trace-id":
                trace_incoming = value
                continue
            sent.append((name, value))
        sent.append(("X-Forwarded-For", ", ".join([v for v in xff_values if v] + [client_ip])))
        sent.append(("X-Forwarded-Proto", "https"))
        sent.append(("X-Forwarded-Port", str(config.https_port)))
        trace_value, trace_root = apply_trace_header(trace_incoming)
        sent.append(("X-Amzn-Trace-Id", trace_value))
        if body is not None:
            sent.append(("Content-Length", str(len(body))))
        record["trace_root"] = trace_root
        record["trace_id"] = trace_value
        record["target"]["headers_sent"] = redact_headers(sent)

        # --- ターゲット (HTTP) へ転送 ----------------------------------------
        connection = http.client.HTTPConnection(
            config.target_host, config.target_port, timeout=config.connect_timeout
        )
        try:
            try:
                connection.connect()
            except socket.gaierror as exc:
                # 名前解決できない = ターゲット (frontend) が未起動 = 登録ターゲットなし
                record["error"] = f"ターゲットの名前解決に失敗しました ({exc})"
                self._alb_error(503, record, started)
                return
            except ConnectionRefusedError as exc:
                record["error"] = f"ターゲットが接続を拒否しました ({exc})"
                self._alb_error(502, record, started)
                return
            except TimeoutError as exc:
                record["error"] = f"ターゲットへ {config.connect_timeout:g} 秒以内に接続できません ({exc})"
                self._alb_error(504, record, started)
                return
            except OSError as exc:
                record["error"] = f"ターゲットへ接続できません ({exc.__class__.__name__}: {exc})"
                self._alb_error(502, record, started)
                return
            peer = connection.sock.getpeername()
            record["target"]["peer"] = f"{peer[0]}:{peer[1]}"
            connection.sock.settimeout(config.idle_timeout)
            try:
                connection.putrequest(method, self.path, skip_host=True, skip_accept_encoding=True)
                for name, value in sent:
                    connection.putheader(name, value)
                connection.endheaders(body)
                upstream = connection.getresponse()
                payload = upstream.read() if method != "HEAD" else b""
            except TimeoutError as exc:
                record["error"] = (
                    f"ターゲットの応答がアイドルタイムアウト {config.idle_timeout:g} 秒を超えました ({exc})"
                )
                self._alb_error(504, record, started)
                return
            except (ValueError, http.client.InvalidURL) as exc:
                record["error"] = f"要求をターゲットへ転送できません ({exc.__class__.__name__}: {exc})"
                self._alb_error(400, record, started)
                return
            except (OSError, http.client.HTTPException) as exc:
                record["error"] = f"ターゲットの応答を受け取れません ({exc.__class__.__name__}: {exc})"
                self._alb_error(502, record, started)
                return
        finally:
            connection.close()

        upstream_headers = upstream.getheaders()
        location = upstream.getheader("Location")
        record["target_response"] = {
            "status": upstream.status,
            "reason": upstream.reason,
            "location": location,
            "headers": redact_headers(upstream_headers),
        }

        # --- クライアントへ返す (ヘッダは書き換えない) ------------------------
        returned: list[tuple[str, str]] = []
        for name, value in upstream_headers:
            if name.lower() in HOP_BY_HOP or name.lower() == "content-length":
                continue
            returned.append((name, value))
        no_body = method == "HEAD" or upstream.status in (204, 304) or upstream.status < 200
        if method == "HEAD" and upstream.getheader("Content-Length") is not None:
            returned.append(("Content-Length", upstream.getheader("Content-Length")))
        elif not no_body:
            returned.append(("Content-Length", str(len(payload))))
        returned_location = header_value([[n, v] for n, v in returned], "Location")
        record["response"] = {
            "status": upstream.status,
            "location": returned_location,
            # ALB は Location を書き換えない。ターゲットの値と同じであることを記録で示す
            "location_rewritten": returned_location != location,
            "generated_by_alb": False,
        }
        record["duration_ms"] = int((time.monotonic() - started) * 1000)
        # 記録は応答より先に残す (応答を受けた直後に引かれても見つかるように)
        self.server.store.add(record)
        self._access_log(record)

        self.send_response_only(upstream.status, upstream.reason)
        for name, value in returned:
            self.send_header(name, value)
        self.end_headers()
        if not no_body and payload:
            self.wfile.write(payload)

    def _alb_error(self, status: int, record: dict, started: float) -> None:
        """ターゲットへ届かないときに ALB 自身が返す応答 (Server: awselb/2.0)。"""
        reason = ALB_ERROR_REASONS.get(status, "Error")
        body = (
            f"<html>\r\n<head><title>{status} {reason}</title></head>\r\n<body>\r\n"
            f"<center><h1>{status} {reason}</h1></center>\r\n</body>\r\n</html>\r\n"
        ).encode("ascii")
        record["response"] = {"status": status, "location": None, "location_rewritten": False,
                              "generated_by_alb": True}
        record["duration_ms"] = int((time.monotonic() - started) * 1000)
        self.server.store.add(record)
        self._access_log(record)
        self.send_response_only(status, reason)
        self.send_header("Server", ALB_SERVER_HEADER)
        self.send_header("Date", self.date_time_string())
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _access_log(self, record: dict) -> None:
        sent = record["target"]["headers_sent"]
        target_status = (record["target_response"] or {}).get("status", "-")
        response = record["response"] or {}
        log(
            f"https:{record['listener']['port']} client={record['client']['ip']}:{record['client']['port']} "
            f"tls={record['tls']['version']} \"{record['request']['method']} {record['request']['path']} "
            f"{record['request']['http_version']}\" host={record['request']['host']} "
            f"-> {record['target']['url']} peer={record['target']['peer'] or '-'} "
            f"target_status={target_status} status={response.get('status', '-')} "
            f"xfp={header_value(sent, 'X-Forwarded-Proto') or '-'} "
            f"xfport={header_value(sent, 'X-Forwarded-Port') or '-'} "
            f"xff={header_value(sent, 'X-Forwarded-For') or '-'} "
            f"trace=Root={record['trace_root'] or '-'} "
            f"location={response.get('location') or '-'} {record['duration_ms']}ms"
            + (f" error={record['error']}" if record["error"] else "")
        )


# --- 管理用 HTTP API -------------------------------------------------------------
class AdminHandler(BaseHTTPRequestHandler):
    server_version = "alb-front-admin/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        pass  # healthcheck が 10 秒ごとに叩くため出さない

    def _send(self, status: int, payload: object, content_type: str = "application/json") -> None:
        if isinstance(payload, (dict, list)):
            body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        else:
            body = str(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(self.path.split("?", 1)[0]).rstrip("/") or "/"
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        if path in ("/", "/healthz"):
            self._send(200, "alb-front-ok\n", "text/plain")
        elif path == "/config":
            self._send(200, self.server.config.snapshot())
        elif path == "/exchanges":
            limit = 20
            for part in query.split("&"):
                name, _, value = part.partition("=")
                if name == "limit" and value.isdigit():
                    limit = int(value)
            self._send(200, {"generated_at": iso_time(), "exchanges": self.server.store.recent(limit)})
        elif path.startswith("/exchanges/"):
            record = self.server.store.find(path[len("/exchanges/"):])
            if record is None:
                self._send(404, {"error": "転送記録が見つかりません (古い記録は捨てられます)"})
            else:
                self._send(200, record)
        else:
            self._send(404, {"error": f"未対応のパスです: {path}"})


def serve(config: Config) -> int:
    try:
        context = build_server_context(config)
    except (OSError, ssl.SSLError) as exc:
        log(f"ERROR サーバ証明書を読み込めません: cert={config.cert} key={config.key} ({exc})")
        log("ERROR pki-init の発行完了 (docker compose logs pki-init) と pki ボリュームのマウントを確認してください。")
        return CLI_UNAVAILABLE

    store = ExchangeStore(config.history_limit)
    listener = TLSThreadingHTTPServer(("0.0.0.0", config.https_port), ListenerHandler, context, config, store)
    admin = ThreadingHTTPServer(("0.0.0.0", config.admin_port), AdminHandler)
    admin.daemon_threads = True
    admin.config = config
    admin.store = store

    def shutdown(signum, _frame) -> None:
        log(f"シグナル {signum} を受け取ったため停止します。")
        threading.Thread(target=listener.shutdown, daemon=True).start()
        threading.Thread(target=admin.shutdown, daemon=True).start()

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, shutdown)
        except (ValueError, OSError):
            pass

    log("frontend 向け ALB の偽装を開始します (HTTPS リスナー → HTTP ターゲットグループ)")
    log(f"listener : HTTPS:{config.https_port} (TLS 1.2 以上 / 証明書 {config.cert})")
    log(f"target   : {config.target} (ターゲットグループのプロトコル = HTTP)")
    log(f"headers  : X-Forwarded-For=append / X-Forwarded-Proto=https / "
        f"X-Forwarded-Port={config.https_port} / X-Amzn-Trace-Id / Host は透過 / Location は書き換えない")
    log(f"admin    : http://0.0.0.0:{config.admin_port}/exchanges (転送記録) /config /healthz")
    admin_thread = threading.Thread(target=admin.serve_forever, kwargs={"poll_interval": 0.5}, daemon=True)
    admin_thread.start()
    try:
        listener.serve_forever(poll_interval=0.5)
    finally:
        listener.server_close()
        admin.server_close()
    log("停止しました。")
    return CLI_OK


# --- CLI: 共通 ------------------------------------------------------------------
def admin_get(config: Config, path: str, timeout: float = 10.0) -> dict | str:
    request = urllib.request.Request(f"http://127.0.0.1:{config.admin_port}{path}")
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - localhost 固定
        text = response.read().decode("utf-8")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    """接続先 (127.0.0.1) と、名乗るホスト名 (SNI / Host) を分けた HTTPS 接続。"""

    def __init__(self, connect_host: str, host: str, port: int, context: ssl.SSLContext, timeout: float):
        super().__init__(host, port, timeout=timeout, context=context)
        self.connect_host = connect_host

    def connect(self) -> None:
        sock = socket.create_connection((self.connect_host, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def client_context(config: Config, verify: bool) -> ssl.SSLContext:
    if verify:
        context = ssl.create_default_context(cafile=config.ca_bundle)
    else:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])
    return context


def describe_name(name: tuple) -> str:
    short = {"commonName": "CN", "organizationName": "O", "organizationalUnitName": "OU",
             "countryName": "C", "stateOrProvinceName": "ST", "localityName": "L"}
    return ", ".join(f"{short.get(key, key)}={value}" for rdn in name or () for key, value in rdn)


def https_call(config: Config, method: str, path: str, headers: dict,
               max_body: int = BODY_PREVIEW_BYTES) -> dict:
    """偽装 ALB の HTTPS リスナーへクライアントとして要求する (リダイレクトは辿らない)。

    サーバ証明書は ALB_FRONT_CA_BUNDLE で検証する。検証できない場合 (自己署名リーフへ
    切り替えた等) は検証なしでやり直し、その旨を残す (確認したいのは TLS で届くこと)。
    """
    result: dict = {"url": f"https://{config.client_authority}{path}", "method": method, "error": "",
                    "verify": "", "tls": {}, "status": None, "reason": "", "headers": [], "body": ""}
    started = time.monotonic()
    verify_error = ""
    for verify in (True, False):
        if verify and not os.path.isfile(config.ca_bundle):
            verify_error = f"CA バンドルがありません ({config.ca_bundle})"
            continue
        try:
            context = client_context(config, verify)
        except (OSError, ssl.SSLError) as exc:
            verify_error = f"CA バンドルを読み込めません ({config.ca_bundle}: {exc})"
            continue
        connection = PinnedHTTPSConnection("127.0.0.1", config.check_host, config.https_port,
                                           context, timeout=30)
        try:
            connection.connect()
            sock = connection.sock
            cipher = sock.cipher()
            der = sock.getpeercert(binary_form=True) or b""
            cert = sock.getpeercert() if verify else {}
            result["tls"] = {
                "version": sock.version(),
                "cipher": cipher[0] if cipher else None,
                "alpn": sock.selected_alpn_protocol(),
                "subject": describe_name(cert.get("subject")) if cert else "",
                "issuer": describe_name(cert.get("issuer")) if cert else "",
                "san": ", ".join(f"{kind}:{value}" for kind, value in cert.get("subjectAltName", ()))
                if cert else "",
                "not_after": cert.get("notAfter", "") if cert else "",
                "sha256": hashlib.sha256(der).hexdigest() if der else "",
            }
            result["verify"] = (
                f"OK ({config.ca_bundle} で検証 / ホスト名 {config.check_host} は SAN に一致)"
                if verify else f"検証なしで接続 ({verify_error})"
            )
            connection.request(method, path, headers=headers)
            response = connection.getresponse()
            body = response.read(max_body) if method != "HEAD" else b""
            result["status"] = response.status
            result["reason"] = response.reason
            result["headers"] = [[name, value] for name, value in response.getheaders()]
            result["body"] = body.decode("utf-8", "replace")
            break
        except ssl.SSLCertVerificationError as exc:
            verify_error = f"証明書を検証できません: {exc.verify_message or exc}"
            continue
        except (OSError, http.client.HTTPException) as exc:
            result["error"] = f"{exc.__class__.__name__}: {exc}"
            break
        finally:
            connection.close()
    result["duration_ms"] = int((time.monotonic() - started) * 1000)
    return result


def http_direct_call(config: Config, method: str, path: str) -> dict:
    """偽装 ALB を通さず、ターゲットへ直接 HTTP で要求する (X-Forwarded-* なし)。"""
    result: dict = {"url": f"{config.target}{path}", "error": "", "status": None, "reason": "",
                    "headers": [], "peer": None}
    connection = http.client.HTTPConnection(config.target_host, config.target_port,
                                            timeout=config.connect_timeout)
    try:
        connection.connect()
        peer = connection.sock.getpeername()
        result["peer"] = f"{peer[0]}:{peer[1]}"
        connection.sock.settimeout(config.idle_timeout)
        connection.request(method, path, headers={"User-Agent": CHECK_USER_AGENT, "Accept": "*/*"})
        response = connection.getresponse()
        if method != "HEAD":
            response.read(BODY_PREVIEW_BYTES)
        result["status"] = response.status
        result["reason"] = response.reason
        result["headers"] = [[name, value] for name, value in response.getheaders()]
    except (OSError, http.client.HTTPException) as exc:
        result["error"] = f"{exc.__class__.__name__}: {exc}"
    finally:
        connection.close()
    return result


def scheme_of(location: str | None) -> str:
    if not location:
        return "-"
    scheme = urlsplit(location.strip()).scheme.lower()
    return scheme or "relative"


def first_token(value: str | None) -> str:
    return (value or "").split(",", 1)[0].strip().lower()


def context_root_of(path: str) -> str:
    """/iwinmichl/api/... → /iwinmichl (2 段目が無いパスは対象外)。"""
    segments = [segment for segment in path.split("?", 1)[0].split("/") if segment]
    return f"/{segments[0]}" if len(segments) >= 2 else ""


# --- CLI: report -----------------------------------------------------------------
def cmd_report(args: argparse.Namespace) -> int:
    config = Config()
    path = args.path or config.check_path
    method = (args.method or "GET").upper()
    if not path.startswith("/"):
        print(f"[ERROR] API のパスは / で始めてください: {path}", file=sys.stderr)
        return CLI_UNAVAILABLE

    try:
        admin_get(config, "/healthz")
    except (urllib.error.URLError, OSError) as exc:
        print(f"[ERROR] 偽装 ALB の常駐プロセス (alb-front.py serve) へ接続できません: {exc}", file=sys.stderr)
        print("[ERROR] docker compose logs alb-front を確認してください。", file=sys.stderr)
        return CLI_UNAVAILABLE

    root = new_trace_value()
    main = https_call(config, method, path, {
        "X-Amzn-Trace-Id": f"Root={root}",
        "User-Agent": CHECK_USER_AGENT,
        "Accept": "*/*",
    })
    exchange: dict | None = None
    if not main["error"]:
        for _attempt in range(10):
            try:
                found = admin_get(config, f"/exchanges/{root}")
                exchange = found if isinstance(found, dict) else None
                break
            except urllib.error.HTTPError as exc:
                if exc.code != 404:
                    break
                time.sleep(0.2)
            except (urllib.error.URLError, OSError):
                break

    location = header_value(main["headers"], "Location")
    diag = {name.lower()[len(DIAG_PREFIX):]: value for name, value in main["headers"]
            if name.lower().startswith(DIAG_PREFIX)}
    redirected = main["status"] is not None and 300 <= main["status"] < 400 and bool(location)

    follow = None
    if redirected and not args.no_follow:
        absolute = urljoin(main["url"], location)
        parts = urlsplit(absolute)
        if parts.scheme == "https" and parts.netloc.lower() == config.client_authority.lower():
            follow = https_call(config, "GET", parts.path + (f"?{parts.query}" if parts.query else ""),
                                {"User-Agent": CHECK_USER_AGENT, "Accept": "application/json, */*"},
                                max_body=262144)
            follow["target_url"] = absolute
        else:
            follow = {"skipped": f"Location の宛先 ({parts.scheme}://{parts.netloc}) が"
                                 f"この偽装 ALB (https://{config.client_authority}) ではないため辿りません"}

    control = None if args.no_control else http_direct_call(config, method, path)
    context_root = context_root_of(path)
    container = None
    if context_root and not args.no_context_root:
        container = https_call(config, "GET", context_root,
                               {"User-Agent": CHECK_USER_AGENT, "Accept": "*/*"})
        container["path"] = context_root

    return print_report(config, path, method, root, main, exchange, location, diag, follow, control, container)


def print_report(config: Config, path: str, method: str, root: str, main: dict, exchange: dict | None,
                 location: str | None, diag: dict, follow: dict | None, control: dict | None,
                 container: dict | None) -> int:
    marks: list[tuple[str, str]] = []
    print("")
    print("════════════ Location ヘッダ確認レポート (偽装 ALB: alb-front) ════════════")
    print(f"確認対象 API       : {method} {path}")
    print(f"実行日時           : {display_time()}")
    print(f"経路               : クライアント ──https──▶ alb-front:{config.https_port} (TLS 終端)"
          f" ──http──▶ {config.target_host}:{config.target_port} (JBoss EAP)")
    print(f"トレース ID        : Root={root}  (docker compose logs alb-front で同じ値を検索できる)")

    # [1] クライアント → 偽装 ALB ----------------------------------------------
    print("")
    print("[1] クライアント → 偽装 ALB (HTTPS リスナー)                      … https")
    print(f"  要求               : {method} {main['url']}  (接続先 127.0.0.1:{config.https_port})")
    if main["error"]:
        print(f"  エラー             : {main['error']}")
        print("")
        print("判定結果           : 実行不能 (偽装 ALB の HTTPS リスナーへ接続できません)")
        print("════════════════════════════════════════════════════════════════")
        return CLI_UNAVAILABLE
    tls = main["tls"]
    print(f"  TLS                : {tls.get('version')} / {tls.get('cipher')} (ALPN {tls.get('alpn') or '-'})")
    if tls.get("subject"):
        print(f"  サーバ証明書       : {tls['subject']}  (発行者 {tls.get('issuer')})")
        print(f"  SAN                : {tls.get('san') or '-'}")
    print(f"  証明書 SHA-256     : {tls.get('sha256') or '-'}")
    print(f"  証明書の検証       : {main['verify']}")
    print(f"  送ったヘッダ       : Host: {config.client_authority} / X-Amzn-Trace-Id: Root={root}")
    marks.append(("OK", f"クライアント → 偽装 ALB は https ({tls.get('version')} / {tls.get('cipher')})"))

    # [2] 偽装 ALB → ターゲット ------------------------------------------------
    print("")
    print(f"[2] 偽装 ALB → {config.target_host} (ターゲットグループ HTTP)             … http")
    sent_proto = None
    if exchange is None:
        print("  転送記録           : 取得できず (偽装 ALB の /exchanges に該当する記録がありません)")
        marks.append(("--", "偽装 ALB の転送記録を取得できなかったため、ALB → ターゲットの区間は未確認"))
    else:
        sent = exchange["target"]["headers_sent"]
        sent_proto = header_value(sent, "X-Forwarded-Proto")
        print(f"  転送先             : {exchange['target']['url']}  (接続先 {exchange['target']['peer'] or '-'})")
        print(f"  受けた TLS / SNI   : {exchange['tls']['version']} / {exchange['tls']['cipher']}"
              f" / SNI={exchange['tls']['sni'] or '-'}")
        print("  付与・上書きしたヘッダ:")
        for name in ("X-Forwarded-For", "X-Forwarded-Proto", "X-Forwarded-Port", "X-Amzn-Trace-Id"):
            print(f"    {name:<18}: {header_value(sent, name) or '-'}")
        print(f"    {'Host (透過)':<16}: {header_value(sent, 'Host') or '-'}")
        target_response = exchange.get("target_response") or {}
        print(f"  ターゲットの応答   : {target_response.get('status', '-')} {target_response.get('reason', '')}"
              f" / Location: {target_response.get('location') or '-'}".rstrip())
        if exchange.get("error"):
            print(f"  エラー             : {exchange['error']}")
        if exchange["target"]["url"].startswith("http://"):
            marks.append(("OK", f"偽装 ALB → {config.target_host} は http "
                                f"(接続先 {exchange['target']['peer'] or '-'}、TLS なし)"))
        if first_token(sent_proto) == "https":
            marks.append(("OK", "偽装 ALB が X-Forwarded-Proto: https を付与してターゲットへ送信"))
        else:
            marks.append(("NG", f"偽装 ALB が送った X-Forwarded-Proto が https ではない ({sent_proto})"))

    response_record = (exchange or {}).get("response") or {}
    if response_record.get("generated_by_alb"):
        print("")
        print(f"判定結果           : 実行不能 (ターゲットへ届かないため偽装 ALB が "
              f"{response_record.get('status')} を返しました: {exchange.get('error')})")
        print(f"                     docker compose ps {config.target_host} / docker compose logs "
              f"{config.target_host} を確認してください。")
        print("════════════════════════════════════════════════════════════════")
        return CLI_UNAVAILABLE

    # [3] JBoss EAP が受け取った内容 (dhapp の診断ヘッダ) -------------------------
    print("")
    print("[3] JBoss EAP (frontend) が受け取った内容 (X-Redirect-Check-* 診断ヘッダ)")
    diag_proto = diag.get("forwarded-proto")
    diag_scheme = diag.get("scheme")
    if not diag:
        print("  (対象 API が診断ヘッダを返さないため、JBoss EAP 側の受信内容は Location から推定する)")
        marks.append(("--", "JBoss EAP 側の受信内容は未確認 (診断ヘッダを返すのは dhapp の "
                            "/api/redirect-check/redirect)"))
    else:
        print(f"  受信した X-Forwarded-Proto : {diag_proto}")
        print(f"  受信した X-Forwarded-For   : {diag.get('forwarded-for')}")
        print(f"  受信した X-Amzn-Trace-Id   : {diag.get('trace-id')}")
        print(f"  実際の通信                 : {diag.get('transport')} (受けたポート {diag.get('local-port')})")
        print(f"  request.getScheme()        : {diag_scheme}")
        print(f"  request.isSecure()         : {diag.get('secure')}")
        print(f"  request.getRemoteAddr()    : {diag.get('remote-addr')}")
        forwarding = diag.get("proxy-address-forwarding") or "-"
        print(f"  proxy-address-forwarding   : {forwarding}"
              + ("  ← false のリスナーは X-Forwarded-Proto を読まない" if "=false" in forwarding else ""))
        if first_token(diag_proto) == "https":
            marks.append(("OK", "JBoss EAP が X-Forwarded-Proto: https を受信 (ALB の情報が届いている)"))
        else:
            marks.append(("NG", f"JBoss EAP に X-Forwarded-Proto: https が届いていない ({diag_proto})"))
        if (diag_scheme or "").lower() == "https":
            marks.append(("OK", f"JBoss EAP は https と認識 (通信は {diag.get('transport')} のまま)"))
        else:
            marks.append(("NG", f"JBoss EAP は {diag_scheme} と認識している (X-Forwarded-Proto を反映していない)"))

    # [4] クライアントへ返った Location ------------------------------------------
    print("")
    print("[4] クライアントへ返った Location")
    print(f"  ステータス         : {main['status']} {main['reason']}")
    print(f"  Location           : {location or '(なし)'}")
    location_scheme = scheme_of(location)
    redirected = main["status"] is not None and 300 <= main["status"] < 400 and bool(location)
    if exchange is not None and redirected:
        rewritten = response_record.get("location_rewritten")
        print(f"  ALB での書き換え   : {'あり' if rewritten else 'なし (ターゲットの Location をそのまま返却)'}")
    if redirected:
        if location_scheme == "https":
            marks.append(("OK", "Location は https で返却 (偽装 ALB は書き換えていない)"))
        elif location_scheme == "relative":
            marks.append(("OK", "Location は相対 URL (ブラウザは元の https を引き継ぐ)"))
        else:
            marks.append(("NG", f"Location が {location_scheme} で返却 (ブラウザは {location_scheme} へ遷移する)"))
    if follow is not None:
        if follow.get("skipped"):
            print(f"  Location を辿る    : {follow['skipped']}")
        elif follow.get("error"):
            print(f"  Location を辿る    : GET {follow['target_url']} → エラー {follow['error']}")
            marks.append(("注意", "Location を辿った先 (リダイレクト先) へ到達できない"))
        else:
            summary = ""
            try:
                landing = json.loads(follow.get("body") or "")
                if isinstance(landing, dict) and "recognizedScheme" in landing:
                    summary = (f" (landing: status={landing.get('status')}, "
                               f"scheme={landing.get('recognizedScheme')})")
            except json.JSONDecodeError:
                pass
            print(f"  Location を辿る    : GET {follow['target_url']} → {follow['status']} "
                  f"{follow['reason']}{summary}")
            if follow["status"] is not None and follow["status"] < 400:
                marks.append(("OK", f"Location を https で辿り、リダイレクト先から {follow['status']} が返った"))
            else:
                marks.append(("注意", f"Location を辿った先が {follow['status']} を返した"))

    # [5] 対照実験 ---------------------------------------------------------------
    if control is not None:
        print("")
        print(f"[5] 対照実験: 偽装 ALB を通さず {config.target_host} へ直接 http (X-Forwarded-* なし)")
        print(f"  要求               : {method} {control['url']}  (接続先 {control['peer'] or '-'})")
        if control["error"]:
            print(f"  エラー             : {control['error']}")
        else:
            control_location = header_value(control["headers"], "Location")
            control_scheme = scheme_of(control_location)
            print(f"  ステータス         : {control['status']} {control['reason']}")
            print(f"  Location           : {control_location or '(なし)'}")
            if not control_location or not redirected:
                marks.append(("--", "対照実験はリダイレクトが揃わないため比較しない"))
            elif location_scheme != "https":
                marks.append(("--", f"対照実験も {control_scheme} ([4] と同じ。X-Forwarded-Proto の有無で"
                                    "結果が変わらない = 反映されていない)"))
            elif control_scheme == "http":
                marks.append(("OK", "対照実験: ヘッダ無しでは http → [4] の https は X-Forwarded-Proto 由来"))
            elif control_scheme == "https":
                marks.append(("注意", "対照実験でも https (X-Forwarded-Proto に依存せず https を固定している可能性)"))

    # [6] JBoss EAP 自身のリダイレクト -------------------------------------------
    if container is not None:
        print("")
        print(f"[6] JBoss EAP 自身のリダイレクト (コンテキストルート {container['path']} → "
              f"{container['path']}/)")
        if container["error"]:
            print(f"  エラー             : {container['error']}")
        else:
            container_location = header_value(container["headers"], "Location")
            container_scheme = scheme_of(container_location)
            print(f"  ステータス         : {container['status']} {container['reason']}")
            print(f"  Location           : {container_location or '(なし)'}")
            if container["status"] is None or not (300 <= container["status"] < 400) or not container_location:
                marks.append(("--", "コンテキストルートのリダイレクトは返らなかった (対象外)"))
            elif container_scheme in ("https", "relative"):
                marks.append(("OK", "JBoss EAP 自身のリダイレクトも https (JBoss EAP 側で反映されている)"))
            elif location_scheme == "https":
                marks.append(("注意", "JBoss EAP 自身のリダイレクトは http (アプリ側だけで補正している可能性。"
                                    "コンテキストルートや FORM 認証のリダイレクトは http のまま。"
                                    "proxy-address-forwarding を確認)"))
            else:
                marks.append(("NG", f"JBoss EAP 自身のリダイレクトも {container_scheme} (JBoss EAP が "
                                    "X-Forwarded-Proto を反映していない)"))

    # [判定] ---------------------------------------------------------------------
    print("")
    print("[判定]")
    for mark, text in marks:
        print(f"  [{mark}] {text}")
    has_ng = any(mark == "NG" for mark, _ in marks)
    print("")
    if not redirected:
        print(f"判定結果           : 判定保留 (リダイレクトが返りませんでした: {main['status']} {main['reason']})")
        print("                     API のパス・WAR のデプロイ状況を確認してください "
              f"(既定は {config.check_path})。")
        code = CLI_PENDING
    elif has_ng:
        print("判定結果           : NG (Location が https で返らない / X-Forwarded-Proto が連携されていない)")
        print("対処               : ALB からの通信を受ける http-listener で proxy-address-forwarding を有効にする")
        print("                     /subsystem=undertow/server=default-server/http-listener=default"
              ":write-attribute(name=proxy-address-forwarding,value=true)")
        print("                     → reload (ローカルの frontend なら次の 2 コマンド)")
        print("                     docker compose exec frontend /opt/server/bin/jboss-cli.sh --connect "
              "--command='/subsystem=undertow/server=default-server/http-listener=default"
              ":write-attribute(name=proxy-address-forwarding,value=true)'")
        print("                     docker compose exec frontend /opt/server/bin/jboss-cli.sh --connect "
              "--command=':reload'")
        code = CLI_NG
    else:
        print("判定結果           : OK (ALB の X-Forwarded-Proto: https が JBoss EAP に連携され、"
              "Location は https で返る)")
        code = CLI_OK
    print("════════════════════════════════════════════════════════════════")
    return code


# --- CLI: その他 ---------------------------------------------------------------
def cmd_exchanges(args: argparse.Namespace) -> int:
    config = Config()
    try:
        document = admin_get(config, f"/exchanges?limit={max(args.limit, 1)}")
    except (urllib.error.URLError, OSError) as exc:
        print(f"[ERROR] 偽装 ALB の管理 API へ接続できません: {exc}", file=sys.stderr)
        return CLI_UNAVAILABLE
    print(json.dumps(document, ensure_ascii=False, indent=2))
    return CLI_OK


def cmd_config(_args: argparse.Namespace) -> int:
    print(json.dumps(Config().snapshot(), ensure_ascii=False, indent=2))
    return CLI_OK


def cmd_default_path(_args: argparse.Namespace) -> int:
    print(Config().check_path)
    return CLI_OK


def cmd_ready(_args: argparse.Namespace) -> int:
    config = Config()
    try:
        if admin_get(config, "/healthz", timeout=5) != "alb-front-ok\n":
            return CLI_NG
        context = client_context(config, verify=False)
        with socket.create_connection(("127.0.0.1", config.https_port), timeout=5) as sock:
            with context.wrap_socket(sock, server_hostname=config.check_host):
                pass
        return CLI_OK
    except Exception:
        return CLI_NG


def cmd_serve(_args: argparse.Namespace) -> int:
    return serve(Config())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="frontend 向け ALB (HTTPS → HTTP) の偽装")
    subparsers = parser.add_subparsers(dest="command")

    serve_parser = subparsers.add_parser("serve", help="HTTPS リスナーと管理 API を常駐させる")
    serve_parser.set_defaults(func=cmd_serve)

    report_parser = subparsers.add_parser(
        "report", help="偽装 ALB 経由で API を呼び、Location ヘッダ確認レポートを出力する")
    report_parser.add_argument("path", nargs="?", help="確認する API のパス (既定: ALB_FRONT_CHECK_PATH)")
    report_parser.add_argument("--method", default="GET", help="HTTP メソッド (既定 GET)")
    report_parser.add_argument("--no-follow", action="store_true", help="Location を辿らない")
    report_parser.add_argument("--no-control", action="store_true",
                               help="対照実験 (ターゲットへ直接 http) を行わない")
    report_parser.add_argument("--no-context-root", action="store_true",
                               help="コンテキストルートのリダイレクト確認を行わない")
    report_parser.set_defaults(func=cmd_report)

    exchanges_parser = subparsers.add_parser("exchanges", help="直近の転送記録を JSON で出力する")
    exchanges_parser.add_argument("--limit", type=int, default=20)
    exchanges_parser.set_defaults(func=cmd_exchanges)

    subparsers.add_parser("config", help="リスナー / ターゲットの設定を JSON で出力する").set_defaults(
        func=cmd_config)
    subparsers.add_parser("default-path", help="既定の確認 API のパスを出力する").set_defaults(
        func=cmd_default_path)
    subparsers.add_parser("ready", help="自身の生存確認 (compose healthcheck 用)").set_defaults(func=cmd_ready)

    parser.set_defaults(func=cmd_serve)
    return parser


def main(argv: list[str]) -> int:
    configure_stdio()
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except ValueError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return CLI_UNAVAILABLE
    except KeyboardInterrupt:
        return CLI_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
