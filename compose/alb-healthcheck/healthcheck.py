#!/usr/bin/env python3
# =============================================================================
# ALB ターゲットグループのヘルスチェックのローカル代替 (alb-healthcheck)
# -----------------------------------------------------------------------------
# 実 AWS では ECS サービスに登録されたタスクへ、ALB (Application Load Balancer)
# がターゲットグループのヘルスチェック設定に従って定期的に HTTP 要求を投げ、
# その「ステータスコード」と「連続成功 / 連続失敗の回数」からターゲットの状態
# (initial / healthy / unhealthy) を導出する。ターゲットが unhealthy になると
# ALB はルーティングを止め、ECS はタスクを置き換える。
#
# このスクリプトはその仕組みだけをローカルへ持ち込む。compose の
# `healthcheck:` (= ECS タスク定義の healthCheck。コンテナ内で curl を実行する)
# とは別物で、★コンテナの外から★ ALB と同じ要求を投げるのが目的である。
#
# ALB と同じにしている点:
#   - 要求は  GET <path>  / ヘッダは Host: <target>:<port>,
#     User-Agent: ELB-HealthChecker/2.0, Connection: close
#   - 応答のステータスコードが matcher (HttpCode) に含まれるときだけ成功
#   - timeout_seconds を超えた応答は失敗 (Target.Timeout)
#   - healthy_threshold_count 回連続成功で healthy へ、
#     unhealthy_threshold_count 回連続失敗で unhealthy へ遷移する
#   - 登録直後は initial (Elb.RegistrationInProgress →
#     Elb.InitialHealthChecking) で、閾値に達するまで healthy にならない
#   - 失敗理由は ALB と同じ理由コードで表す
#       Target.ResponseCodeMismatch … matcher に含まれないステータスコード
#       Target.Timeout              … timeout 超過
#       Target.FailedHealthChecks   … 接続不可 / 名前解決不可 / 応答不正
#   - ターゲットグループのプロトコルが HTTPS の場合、ALB はターゲット証明書を
#     検証しない (自己署名でもよい) ため、こちらも検証しない
#
# ALB と違う点 (ローカル都合):
#   - ターゲットは IP ではなく compose サービス名 (DNS 名) で指定する
#   - ターゲットは 1 グループ 1 つ (ECS の 1 タスク構成に合わせる)
#   - draining / unused / unavailable の状態は扱わない
#
# 【使い方】
#   常駐 (compose の command):
#     python3 healthcheck.py serve
#   コンテナ内から手動実行 (docker exec):
#     python3 healthcheck.py report frontend    # 状態 + その場のチェック結果
#     python3 healthcheck.py report --all       # 全ターゲットグループ
#     python3 healthcheck.py check backend      # その場のチェックだけ
#     python3 healthcheck.py state              # 状態を JSON で出力
#     python3 healthcheck.py list-services      # 対象 compose サービス名の一覧
#     python3 healthcheck.py has-service front  # 対象かどうかを終了コードで返す
#     python3 healthcheck.py ready              # 自身の HTTP API の生存確認
#
#   report / check の終了コード:
#     0 = 判定 OK (healthy かつその場のチェックも成功)
#     1 = 判定 NG (unhealthy、またはその場のチェックが失敗)
#     2 = 実行不能 (設定不備・状態 API へ接続できない等)
#     3 = 判定保留 (initial。healthy 閾値に達していない起動直後)
#
# 【HTTP API】(既定 :8080。ホストへは compose の ports で公開する)
#   GET  /healthz                  … このサービス自身の生存確認
#   GET  /targets                  … 全ターゲットグループの設定・状態・履歴 (JSON)
#   GET  /targets/<名前>            … 1 つ分 (ターゲットグループ名 / compose サービス名)
#   GET  /targets/<名前>/check      … その場で 1 回チェックする (POST も可)
#   POST /targets/<名前>/check      …   ※状態機械 (連続回数) には反映しない
#
# 標準ライブラリだけで動く (python:3.12-slim をそのまま使う)。
# =============================================================================
from __future__ import annotations

import argparse
import http.client
import json
import os
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
from urllib.parse import unquote

# ALB のヘルスチェッカが名乗る User-Agent。実 ALB と同じ値にしてあるので、
# ターゲット側のアクセスログでも「ALB からのヘルスチェック」として区別できる。
ELB_USER_AGENT = "ELB-HealthChecker/2.0"

DEFAULT_TARGETS_FILE = "/etc/alb-healthcheck/targets.json"
DEFAULT_LISTEN_PORT = 8080
DEFAULT_HISTORY_LIMIT = 10
BODY_PREVIEW_BYTES = 200

# 表示用タイムゾーン (JST)。ログ・レポートの時刻表記だけに使う。
DISPLAY_TZ = timezone(timedelta(hours=9), "JST")

# ターゲットの状態 (ALB の TargetHealth.State のうちこの構成で起きるもの)
STATE_INITIAL = "initial"
STATE_HEALTHY = "healthy"
STATE_UNHEALTHY = "unhealthy"

# ALB の TargetHealth.Reason
REASON_REGISTRATION = "Elb.RegistrationInProgress"
REASON_INITIAL = "Elb.InitialHealthChecking"
REASON_CODE_MISMATCH = "Target.ResponseCodeMismatch"
REASON_TIMEOUT = "Target.Timeout"
REASON_FAILED = "Target.FailedHealthChecks"

DESCRIPTION_REGISTRATION = "Target registration is in progress"
DESCRIPTION_INITIAL = "Health checks in progress"
DESCRIPTION_TIMEOUT = "Request timed out"
DESCRIPTION_FAILED = "Health checks failed"

# ヘルスチェックの「戻り値」。compose / ECS タスク定義の healthcheck が使う
# `curl -fs` の終了コードに合わせてあるので、コンテナ内のヘルスチェック結果と
# 同じ尺度で読める (0 以外なら失敗)。
EXIT_OK = 0
EXIT_RESOLVE = 6         # curl: CURLE_COULDNT_RESOLVE_HOST
EXIT_CONNECT = 7         # curl: CURLE_COULDNT_CONNECT
EXIT_HTTP_MISMATCH = 22  # curl: CURLE_HTTP_RETURNED_ERROR (--fail が 4xx/5xx で返す)
EXIT_TIMEOUT = 28        # curl: CURLE_OPERATION_TIMEDOUT
EXIT_RECV_ERROR = 56     # curl: CURLE_RECV_ERROR

# report / check サブコマンドの終了コード
CLI_OK = 0
CLI_NG = 1
CLI_UNAVAILABLE = 2
CLI_PENDING = 3


def configure_stdio() -> None:
    """日本語と罫線を含むレポートを、ロケール既定の文字コードに関係なく出力する。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", newline="\n")
        except Exception:
            pass


def display_time(epoch: float | None) -> str:
    if not epoch:
        return "-"
    return datetime.fromtimestamp(epoch, DISPLAY_TZ).strftime("%Y-%m-%d %H:%M:%S %Z")


def iso_time(epoch: float | None) -> str:
    if not epoch:
        return ""
    return datetime.fromtimestamp(epoch, DISPLAY_TZ).isoformat(timespec="seconds")


def log(message: str) -> None:
    """docker compose logs alb-healthcheck で読む 1 行ログ (ALB のアクセスログ相当)。"""
    print(f"{iso_time(time.time())} [alb-healthcheck] {message}", flush=True)


# --- matcher (HttpCode) ------------------------------------------------------
# ALB の matcher と同じ書き方を受け付ける: "200" / "200,301" / "200-299" / 混在。
def parse_matcher(spec: object) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    for part in str(spec).split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            low_text, high_text = part.split("-", 1)
            low, high = int(low_text), int(high_text)
        else:
            low = high = int(part)
        if not (100 <= low <= high <= 599):
            raise ValueError(f"matcher の範囲が不正です: {part}")
        ranges.append((low, high))
    if not ranges:
        raise ValueError("matcher が空です")
    return ranges


def matcher_contains(ranges: list[tuple[int, int]], code: int) -> bool:
    return any(low <= code <= high for low, high in ranges)


# --- ターゲットグループ ------------------------------------------------------
class TargetGroup:
    """ALB のターゲットグループ 1 つ (ヘルスチェック設定 + 導出した状態)。"""

    def __init__(self, spec: dict, index: int, history_limit: int) -> None:
        if not isinstance(spec, dict):
            raise ValueError(f"target_groups[{index}] がオブジェクトではありません")

        def required(key: str) -> object:
            if key not in spec or spec[key] in ("", None):
                raise ValueError(f"target_groups[{index}] に {key} がありません")
            return spec[key]

        self.name = str(required("name"))
        # ヘルスチェック対象の compose サービス名。build_and_verify.sh の
        # サービス操作メニューは、この値で「どのサービスに ALB ヘルスチェックの
        # 確認メニューを出すか」を判定する。
        self.compose_service = str(required("compose_service"))
        # 参考表示用。ECS タスク定義側のコンテナ名 (compose サービス名とは別)。
        self.ecs_container = str(spec.get("ecs_container") or "")
        self.description = str(spec.get("description") or "")

        self.protocol = str(spec.get("protocol") or "HTTP").upper()
        if self.protocol not in ("HTTP", "HTTPS"):
            raise ValueError(f"{self.name}: protocol は HTTP か HTTPS です: {self.protocol}")
        self.host = str(required("host"))
        self.port = int(required("port"))
        self.path = str(spec.get("path") or "/")
        if not self.path.startswith("/"):
            raise ValueError(f"{self.name}: path は / で始めます: {self.path}")

        self.matcher = str(spec.get("matcher") or "200")
        self.matcher_ranges = parse_matcher(self.matcher)

        self.interval = int(spec.get("interval_seconds") or 30)
        self.timeout = int(spec.get("timeout_seconds") or 5)
        self.healthy_threshold = int(spec.get("healthy_threshold_count") or 5)
        self.unhealthy_threshold = int(spec.get("unhealthy_threshold_count") or 2)
        if self.timeout >= self.interval:
            # 実 ALB も timeout < interval を要求する
            raise ValueError(
                f"{self.name}: timeout_seconds ({self.timeout}) は "
                f"interval_seconds ({self.interval}) より小さくします"
            )
        for label, value in (
            ("healthy_threshold_count", self.healthy_threshold),
            ("unhealthy_threshold_count", self.unhealthy_threshold),
        ):
            if not 2 <= value <= 10:
                raise ValueError(f"{self.name}: {label} は 2〜10 です: {value}")

        self.history_limit = history_limit

        # --- ここから下は状態 (lock で保護) ---
        self.lock = threading.Lock()
        self.state = STATE_INITIAL
        self.reason_code = REASON_REGISTRATION
        self.state_description = DESCRIPTION_REGISTRATION
        self.consecutive_success = 0
        self.consecutive_failure = 0
        self.total_checks = 0
        self.total_success = 0
        self.total_failure = 0
        self.state_changed_at = time.time()
        self.last_check_at: float | None = None
        self.history: list[dict] = []

    @property
    def target(self) -> str:
        return f"{self.host}:{self.port}"

    @property
    def endpoint(self) -> str:
        scheme = "https" if self.protocol == "HTTPS" else "http"
        return f"{scheme}://{self.host}:{self.port}{self.path}"

    def matches_key(self, key: str) -> bool:
        return key in (self.name, self.compose_service)

    def config_snapshot(self) -> dict:
        return {
            "name": self.name,
            "compose_service": self.compose_service,
            "ecs_container": self.ecs_container,
            "description": self.description,
            "protocol": self.protocol,
            "host": self.host,
            "port": self.port,
            "path": self.path,
            "endpoint": self.endpoint,
            "matcher": self.matcher,
            "interval_seconds": self.interval,
            "timeout_seconds": self.timeout,
            "healthy_threshold_count": self.healthy_threshold,
            "unhealthy_threshold_count": self.unhealthy_threshold,
            "user_agent": ELB_USER_AGENT,
        }

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "config": self.config_snapshot(),
                "target_health": {
                    "state": self.state,
                    "reason": self.reason_code,
                    "description": self.state_description,
                    "state_changed_at": iso_time(self.state_changed_at),
                },
                "counters": {
                    "consecutive_success": self.consecutive_success,
                    "consecutive_failure": self.consecutive_failure,
                    "total_checks": self.total_checks,
                    "total_success": self.total_success,
                    "total_failure": self.total_failure,
                    "last_check_at": iso_time(self.last_check_at),
                },
                "history": list(reversed(self.history)),
            }

    def apply(self, result: dict) -> dict:
        """定期チェックの結果を ALB と同じ規則で状態へ反映し、反映後の要約を返す。"""
        with self.lock:
            self.total_checks += 1
            self.last_check_at = result["checked_at"]
            previous_state = self.state

            if result["success"]:
                self.total_success += 1
                self.consecutive_success += 1
                self.consecutive_failure = 0
                if self.state != STATE_HEALTHY and self.consecutive_success >= self.healthy_threshold:
                    self.state = STATE_HEALTHY
                    self.reason_code = ""
                    self.state_description = ""
                elif self.state == STATE_INITIAL:
                    # 閾値に達するまでは initial のまま (ALB と同じ)
                    self.reason_code = REASON_INITIAL
                    self.state_description = DESCRIPTION_INITIAL
            else:
                self.total_failure += 1
                self.consecutive_failure += 1
                self.consecutive_success = 0
                if self.consecutive_failure >= self.unhealthy_threshold:
                    self.state = STATE_UNHEALTHY
                    self.reason_code = result["failure_reason"]
                    self.state_description = result["failure_description"]
                elif self.state == STATE_INITIAL:
                    self.reason_code = REASON_INITIAL
                    self.state_description = DESCRIPTION_INITIAL

            if self.state != previous_state:
                self.state_changed_at = result["checked_at"]

            entry = dict(result)
            entry["state_after"] = self.state
            entry["consecutive_success"] = self.consecutive_success
            entry["consecutive_failure"] = self.consecutive_failure
            self.history.append(entry)
            if len(self.history) > self.history_limit:
                del self.history[: len(self.history) - self.history_limit]

            return {
                "state": self.state,
                "previous_state": previous_state,
                "consecutive_success": self.consecutive_success,
                "consecutive_failure": self.consecutive_failure,
            }


# --- ヘルスチェックの実行 ----------------------------------------------------
def run_health_check(group: TargetGroup) -> dict:
    """ALB と同じ要求を 1 回投げる。状態機械は更新しない (呼び出し側の責務)。"""
    checked_at = time.time()
    started = time.monotonic()
    connection: http.client.HTTPConnection | None = None
    result: dict = {
        "checked_at": checked_at,
        "checked_at_display": display_time(checked_at),
        "request": f"GET {group.endpoint}",
        "status_code": None,
        "reason_phrase": "",
        "matcher": group.matcher,
        "matched": False,
        "success": False,
        "exit_code": EXIT_RECV_ERROR,
        "failure_reason": REASON_FAILED,
        "failure_description": DESCRIPTION_FAILED,
        "error": "",
        "body_preview": "",
        "body_truncated": False,
        "duration_ms": 0,
    }

    try:
        if group.protocol == "HTTPS":
            # 実 ALB もターゲット証明書の検証は行わない (自己署名でも通る)
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            connection = http.client.HTTPSConnection(
                group.host, group.port, timeout=group.timeout, context=context
            )
        else:
            connection = http.client.HTTPConnection(
                group.host, group.port, timeout=group.timeout
            )
        connection.request(
            "GET",
            group.path,
            headers={
                # ALB のヘルスチェックは Host に「ターゲット:ポート」を入れる
                "Host": group.target,
                "User-Agent": ELB_USER_AGENT,
                "Accept": "*/*",
                "Connection": "close",
            },
        )
        response = connection.getresponse()
        body = response.read(BODY_PREVIEW_BYTES + 1)
        status = int(response.status)
        result["status_code"] = status
        result["reason_phrase"] = response.reason or ""
        result["body_truncated"] = len(body) > BODY_PREVIEW_BYTES
        result["body_preview"] = body[:BODY_PREVIEW_BYTES].decode("utf-8", "replace")
        if matcher_contains(group.matcher_ranges, status):
            result["matched"] = True
            result["success"] = True
            result["exit_code"] = EXIT_OK
            result["failure_reason"] = ""
            result["failure_description"] = ""
        else:
            result["exit_code"] = EXIT_HTTP_MISMATCH
            result["failure_reason"] = REASON_CODE_MISMATCH
            result["failure_description"] = f"Health checks failed with these codes: [{status}]"
    except socket.gaierror as exc:
        # 名前解決できない = ターゲットの compose サービスが存在しない / 未起動
        result["exit_code"] = EXIT_RESOLVE
        result["error"] = f"名前解決に失敗しました ({exc.__class__.__name__}: {exc})"
    except TimeoutError as exc:
        result["exit_code"] = EXIT_TIMEOUT
        result["failure_reason"] = REASON_TIMEOUT
        result["failure_description"] = DESCRIPTION_TIMEOUT
        result["error"] = f"timeout {group.timeout}s を超過しました ({exc.__class__.__name__})"
    except ssl.SSLError as exc:
        result["exit_code"] = EXIT_RECV_ERROR
        result["error"] = f"TLS ハンドシェイクに失敗しました ({exc.__class__.__name__}: {exc})"
    except (ConnectionError, OSError) as exc:
        result["exit_code"] = EXIT_CONNECT
        result["error"] = f"接続できません ({exc.__class__.__name__}: {exc})"
    except http.client.HTTPException as exc:
        result["exit_code"] = EXIT_RECV_ERROR
        result["error"] = f"応答を解釈できません ({exc.__class__.__name__}: {exc})"
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass

    result["duration_ms"] = int((time.monotonic() - started) * 1000)
    return result


class HealthCheckRunner:
    """ターゲットグループごとに interval 間隔でヘルスチェックを回す常駐スレッド群。"""

    def __init__(self, groups: list[TargetGroup]) -> None:
        self.groups = groups
        self.stop_event = threading.Event()
        self.threads: list[threading.Thread] = []

    def start(self) -> None:
        for group in self.groups:
            thread = threading.Thread(
                target=self._loop, args=(group,), name=f"hc-{group.name}", daemon=True
            )
            thread.start()
            self.threads.append(thread)

    def stop(self) -> None:
        self.stop_event.set()

    def _loop(self, group: TargetGroup) -> None:
        # ALB はターゲット登録直後からチェックを始めるため、待たずに 1 回目を実行する
        while not self.stop_event.is_set():
            result = run_health_check(group)
            applied = group.apply(result)
            status_text = result["status_code"] if result["status_code"] is not None else "-"
            log(
                f"tg={group.name} target={group.target} GET {group.path} "
                f"status={status_text} matcher={group.matcher} "
                f"result={'success' if result['success'] else 'failure'} "
                f"exit={result['exit_code']} duration={result['duration_ms']}ms "
                f"state={applied['state']} "
                f"streak=success:{applied['consecutive_success']}/"
                f"failure:{applied['consecutive_failure']}"
                + (f" error={result['error']}" if result["error"] else "")
            )
            if applied["state"] != applied["previous_state"]:
                log(
                    f"tg={group.name} target={group.target} "
                    f"状態遷移 {applied['previous_state']} -> {applied['state']} "
                    f"reason={group.reason_code or '-'} "
                    f"description={group.state_description or '-'}"
                )
            self.stop_event.wait(group.interval)


# --- 設定の読み込み ----------------------------------------------------------
def targets_file_path() -> str:
    return os.environ.get("ALB_HEALTHCHECK_TARGETS_FILE") or DEFAULT_TARGETS_FILE


def load_groups() -> list[TargetGroup]:
    path = targets_file_path()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except FileNotFoundError as exc:
        raise ValueError(f"ターゲット定義ファイルがありません: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"ターゲット定義ファイルの JSON を解析できません: {path} ({exc})") from exc

    if not isinstance(document, dict):
        raise ValueError(f"ターゲット定義ファイルの最上位がオブジェクトではありません: {path}")
    specs = document.get("target_groups")
    if not isinstance(specs, list) or not specs:
        raise ValueError(f"target_groups が空です: {path}")

    history_limit = int(
        os.environ.get("ALB_HEALTHCHECK_HISTORY_LIMIT")
        or document.get("history_limit")
        or DEFAULT_HISTORY_LIMIT
    )
    groups = [TargetGroup(spec, index, history_limit) for index, spec in enumerate(specs)]

    names = [group.name for group in groups]
    if len(set(names)) != len(names):
        raise ValueError(f"ターゲットグループ名が重複しています: {names}")
    return groups


def listen_port() -> int:
    return int(os.environ.get("ALB_HEALTHCHECK_LISTEN_PORT") or DEFAULT_LISTEN_PORT)


def find_group(groups: list[TargetGroup], key: str) -> TargetGroup | None:
    for group in groups:
        if group.matches_key(key):
            return group
    return None


# --- HTTP API ----------------------------------------------------------------
class StateHandler(BaseHTTPRequestHandler):
    server_version = "alb-healthcheck/1.0"
    groups: list[TargetGroup] = []

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - 基底クラスの API
        log("api " + (fmt % args))

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
        if self.command != "HEAD":
            self.wfile.write(body)

    def _route(self) -> None:
        path = unquote(self.path.split("?", 1)[0]).rstrip("/") or "/"

        if path in ("/", "/healthz"):
            self._send(200, "alb-healthcheck-ok\n", "text/plain")
            return

        if path == "/targets":
            self._send(
                200,
                {
                    "generated_at": iso_time(time.time()),
                    "user_agent": ELB_USER_AGENT,
                    "target_groups": [group.snapshot() for group in self.groups],
                },
            )
            return

        if path.startswith("/targets/"):
            rest = path[len("/targets/"):]
            run_check = rest.endswith("/check")
            key = rest[: -len("/check")] if run_check else rest
            group = find_group(self.groups, key)
            if group is None:
                self._send(
                    404,
                    {
                        "error": f"ターゲットグループが見つかりません: {key}",
                        "available": [
                            {"name": g.name, "compose_service": g.compose_service}
                            for g in self.groups
                        ],
                    },
                )
                return
            if run_check:
                if self.command not in ("GET", "POST", "HEAD"):
                    self._send(405, {"error": f"許可されていないメソッドです: {self.command}"})
                    return
                # その場のチェックは状態機械へ反映しない (連続回数を乱さないため)
                check = run_health_check(group)
                self._send(
                    200,
                    {
                        "generated_at": iso_time(time.time()),
                        "note": "on-demand check: 状態機械 (連続回数) には反映しません",
                        "check": check,
                        "target_group": group.snapshot(),
                    },
                )
                return
            self._send(200, group.snapshot())
            return

        self._send(404, {"error": f"未対応のパスです: {path}"})

    def do_GET(self) -> None:  # noqa: N802 - 基底クラスの API
        self._route()

    def do_HEAD(self) -> None:  # noqa: N802
        self._route()

    def do_POST(self) -> None:  # noqa: N802
        # 本文は使わないが、読み捨てないと接続が中途半端な状態で残る
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > 0:
            self.rfile.read(length)
        self._route()


def serve(groups: list[TargetGroup]) -> int:
    port = listen_port()
    StateHandler.groups = groups
    server = ThreadingHTTPServer(("0.0.0.0", port), StateHandler)
    runner = HealthCheckRunner(groups)

    def shutdown(signum, _frame) -> None:
        log(f"シグナル {signum} を受け取ったため停止します。")
        runner.stop()
        threading.Thread(target=server.shutdown, daemon=True).start()

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, shutdown)
        except (ValueError, OSError):
            pass

    log(f"ALB ヘルスチェック偽装を開始します (User-Agent: {ELB_USER_AGENT})")
    for group in groups:
        log(
            f"tg={group.name} service={group.compose_service} target={group.endpoint} "
            f"matcher={group.matcher} interval={group.interval}s timeout={group.timeout}s "
            f"healthy_threshold={group.healthy_threshold} "
            f"unhealthy_threshold={group.unhealthy_threshold}"
        )
    log(f"状態 API: http://0.0.0.0:{port}/targets")
    runner.start()
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        runner.stop()
        server.server_close()
    log("停止しました。")
    return 0


# --- CLI (docker exec から使う) ----------------------------------------------
def api_base_url() -> str:
    return f"http://127.0.0.1:{listen_port()}"


def api_get(path: str, method: str = "GET", timeout: float = 20.0) -> dict:
    request = urllib.request.Request(f"{api_base_url()}{path}", method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - localhost 固定
        return json.loads(response.read().decode("utf-8"))


def state_label(state: str) -> str:
    return {
        STATE_HEALTHY: "healthy (ルーティング対象)",
        STATE_UNHEALTHY: "unhealthy (ALB はルーティングを止める / ECS はタスクを置き換える)",
        STATE_INITIAL: "initial (登録直後。healthy 閾値に未到達)",
    }.get(state, state)


def print_history(history: list[dict]) -> None:
    if not history:
        print("  まだ実行されていません。")
        return
    for entry in history:
        status = entry.get("status_code")
        status_text = str(status) if status is not None else "-"
        judgment = "成功" if entry.get("success") else "失敗"
        matched = "一致" if entry.get("matched") else "不一致"
        line = (
            f"  {entry.get('checked_at_display', '-')}  "
            f"status={status_text:<4} matcher={matched:<6} 判定={judgment}  "
            f"戻り値(exit)={entry.get('exit_code')}  "
            f"所要={entry.get('duration_ms')}ms  "
            f"連続 成功{entry.get('consecutive_success')}/失敗{entry.get('consecutive_failure')}"
            f"  → {entry.get('state_after', '-')}"
        )
        print(line)
        if entry.get("error"):
            print(f"      error: {entry['error']}")


def print_group_report(snapshot: dict, check: dict) -> int:
    config = snapshot["config"]
    health = snapshot["target_health"]
    counters = snapshot["counters"]

    ecs_note = f" (ECS: {config['ecs_container']} コンテナ)" if config.get("ecs_container") else ""
    print("")
    print(f"════════════ ALB ヘルスチェック偽装レポート: {config['compose_service']} ════════════")
    print(f"ターゲットグループ : {config['name']}")
    print(f"ターゲット         : {config['host']}:{config['port']}{ecs_note}")
    print(f"要求               : GET {config['endpoint']}")
    print(f"User-Agent         : {config['user_agent']}")
    print(f"matcher (HttpCode) : {config['matcher']}  ← このステータスコードだけを成功と判定")
    print(f"interval / timeout : {config['interval_seconds']}s / {config['timeout_seconds']}s")
    print(
        f"閾値               : healthy={config['healthy_threshold_count']} 回連続成功 / "
        f"unhealthy={config['unhealthy_threshold_count']} 回連続失敗"
    )
    if config.get("description"):
        print(f"備考               : {config['description']}")

    print("")
    print("[ALB が導出したターゲットの状態 (定期ヘルスチェックの積み上げ)]")
    print(f"状態               : {state_label(health['state'])}")
    print(f"理由コード         : {health['reason'] or '-'}")
    print(f"説明               : {health['description'] or '-'}")
    print(f"状態が変わった時刻 : {health['state_changed_at'] or '-'}")
    print(
        f"連続 成功/失敗     : {counters['consecutive_success']} / "
        f"{counters['consecutive_failure']}"
    )
    print(
        f"実行回数           : {counters['total_checks']} "
        f"(成功 {counters['total_success']} / 失敗 {counters['total_failure']})"
    )
    print(f"最終チェック       : {counters['last_check_at'] or '-'}")

    print("")
    print(f"[定期ヘルスチェックの履歴 (新しい順、{len(snapshot['history'])} 件)]")
    print_history(snapshot["history"])

    print("")
    print("[この場で実行したヘルスチェック (ALB と同じ要求)]")
    status = check.get("status_code")
    print(f"実行内容           : {check.get('request')}  (timeout {config['timeout_seconds']}s)")
    if status is None:
        print("ステータスコード   : 取得できず (応答なし)")
    else:
        print(f"ステータスコード   : {status} {check.get('reason_phrase', '')}".rstrip())
    print(
        f"matcher 判定       : "
        f"{'一致' if check.get('matched') else '不一致'} (matcher={config['matcher']})"
    )
    print(f"成功失敗判定       : {'成功' if check.get('success') else '失敗'}")
    print(f"戻り値 (exit)      : {check.get('exit_code')}  ← curl -fs 相当の終了コード")
    if not check.get("success"):
        print(f"失敗理由コード     : {check.get('failure_reason') or '-'}")
        print(f"失敗理由の説明     : {check.get('failure_description') or '-'}")
    if check.get("error"):
        print(f"エラー内容         : {check['error']}")
    print(f"所要時間           : {check.get('duration_ms')}ms")
    body = (check.get("body_preview") or "").replace("\r", "")
    if body:
        suffix = " …(以降省略)" if check.get("body_truncated") else ""
        print(f"応答本文 (先頭 {BODY_PREVIEW_BYTES} bytes){suffix}:")
        for line in body.splitlines() or [""]:
            print(f"  {line}")
    else:
        print("応答本文           : (なし)")
    print("注意: この場のチェックは上の状態機械 (連続回数) には反映しません。")

    if not check.get("success"):
        verdict, code = "NG (この場のヘルスチェックが失敗)", CLI_NG
    elif health["state"] == STATE_UNHEALTHY:
        verdict, code = "NG (ALB 判定は unhealthy のまま)", CLI_NG
    elif health["state"] == STATE_INITIAL:
        verdict = (
            f"判定保留 (initial。healthy には {config['healthy_threshold_count']} 回連続成功が必要"
            f" / 現在 {counters['consecutive_success']} 回)"
        )
        code = CLI_PENDING
    else:
        verdict, code = "OK (healthy かつこの場のチェックも成功)", CLI_OK
    print("")
    print(f"判定結果           : {verdict}")
    print("════════════════════════════════════════════════════════════════")
    return code


def worst_code(codes: list[int]) -> int:
    for candidate in (CLI_UNAVAILABLE, CLI_NG, CLI_PENDING):
        if candidate in codes:
            return candidate
    return CLI_OK


def resolve_keys(groups: list[TargetGroup], key: str | None, want_all: bool) -> list[TargetGroup]:
    if want_all or key is None:
        return list(groups)
    group = find_group(groups, key)
    if group is None:
        available = ", ".join(f"{g.name} ({g.compose_service})" for g in groups)
        raise ValueError(f"ターゲットグループが見つかりません: {key} / 対象: {available}")
    return [group]


def cmd_report(args: argparse.Namespace) -> int:
    groups = load_groups()
    try:
        selected = resolve_keys(groups, args.target, args.all)
    except ValueError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return CLI_UNAVAILABLE

    codes: list[int] = []
    for group in selected:
        try:
            document = api_get(f"/targets/{group.name}/check", method="POST")
        except (urllib.error.URLError, OSError, ValueError) as exc:
            print(
                f"[ERROR] 偽装サービスの状態 API ({api_base_url()}) へ接続できません: {exc}",
                file=sys.stderr,
            )
            print(
                "[ERROR] alb-healthcheck の常駐プロセス (healthcheck.py serve) を確認してください。",
                file=sys.stderr,
            )
            codes.append(CLI_UNAVAILABLE)
            continue
        codes.append(print_group_report(document["target_group"], document["check"]))
    return worst_code(codes) if codes else CLI_UNAVAILABLE


def cmd_check(args: argparse.Namespace) -> int:
    groups = load_groups()
    try:
        selected = resolve_keys(groups, args.target, args.all)
    except ValueError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return CLI_UNAVAILABLE

    codes: list[int] = []
    for group in selected:
        # 常駐プロセスを介さず、この場で ALB と同じ要求を投げる
        check = run_health_check(group)
        status = check["status_code"] if check["status_code"] is not None else "-"
        print(
            f"{group.name} ({group.compose_service}) {check['request']} "
            f"status={status} matcher={group.matcher} "
            f"判定={'成功' if check['success'] else '失敗'} "
            f"戻り値(exit)={check['exit_code']} 所要={check['duration_ms']}ms"
            + (f" error={check['error']}" if check["error"] else "")
        )
        codes.append(CLI_OK if check["success"] else CLI_NG)
    return worst_code(codes) if codes else CLI_UNAVAILABLE


def cmd_state(args: argparse.Namespace) -> int:
    try:
        if args.target:
            groups = load_groups()
            selected = resolve_keys(groups, args.target, False)[0]
            document = api_get(f"/targets/{selected.name}")
        else:
            document = api_get("/targets")
    except ValueError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return CLI_UNAVAILABLE
    except (urllib.error.URLError, OSError) as exc:
        print(f"[ERROR] 状態 API へ接続できません: {exc}", file=sys.stderr)
        return CLI_UNAVAILABLE
    print(json.dumps(document, ensure_ascii=False, indent=2))
    return CLI_OK


def cmd_list_services(_args: argparse.Namespace) -> int:
    # 状態 API を介さず定義ファイルだけを見る (常駐プロセスの状態に依存させない)
    for group in load_groups():
        print(group.compose_service)
    return CLI_OK


def cmd_has_service(args: argparse.Namespace) -> int:
    groups = load_groups()
    return CLI_OK if find_group(groups, args.target) is not None else CLI_NG


def cmd_ready(_args: argparse.Namespace) -> int:
    try:
        request = urllib.request.Request(f"{api_base_url()}/healthz")
        with urllib.request.urlopen(request, timeout=5) as response:  # noqa: S310
            return CLI_OK if response.status == 200 else CLI_NG
    except Exception:
        return CLI_NG


def cmd_serve(_args: argparse.Namespace) -> int:
    return serve(load_groups())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="ALB ターゲットグループのヘルスチェックのローカル代替",
    )
    subparsers = parser.add_subparsers(dest="command")

    serve_parser = subparsers.add_parser("serve", help="常駐して定期ヘルスチェックと状態 API を提供する")
    serve_parser.set_defaults(func=cmd_serve)

    report_parser = subparsers.add_parser(
        "report", help="状態 + その場のヘルスチェック結果を人が読む形式で出力する"
    )
    report_parser.add_argument("target", nargs="?", help="ターゲットグループ名 または compose サービス名")
    report_parser.add_argument("--all", action="store_true", help="全ターゲットグループを対象にする")
    report_parser.set_defaults(func=cmd_report)

    check_parser = subparsers.add_parser("check", help="その場で 1 回だけヘルスチェックする")
    check_parser.add_argument("target", nargs="?", help="ターゲットグループ名 または compose サービス名")
    check_parser.add_argument("--all", action="store_true", help="全ターゲットグループを対象にする")
    check_parser.set_defaults(func=cmd_check)

    state_parser = subparsers.add_parser("state", help="状態を JSON で出力する")
    state_parser.add_argument("target", nargs="?", help="ターゲットグループ名 または compose サービス名")
    state_parser.set_defaults(func=cmd_state)

    list_parser = subparsers.add_parser("list-services", help="対象 compose サービス名を列挙する")
    list_parser.set_defaults(func=cmd_list_services)

    has_parser = subparsers.add_parser(
        "has-service", help="指定名が対象かどうかを終了コードで返す (0=対象)"
    )
    has_parser.add_argument("target", help="ターゲットグループ名 または compose サービス名")
    has_parser.set_defaults(func=cmd_has_service)

    ready_parser = subparsers.add_parser("ready", help="自身の HTTP API の生存確認 (compose healthcheck 用)")
    ready_parser.set_defaults(func=cmd_ready)

    parser.set_defaults(func=cmd_serve)
    return parser


def main(argv: list[str]) -> int:
    configure_stdio()
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except ValueError as exc:
        # 設定不備はすべてここへ来る (実行不能)
        print(f"[ERROR] {exc}", file=sys.stderr)
        return CLI_UNAVAILABLE
    except KeyboardInterrupt:
        return CLI_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
