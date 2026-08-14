#!/usr/bin/env python3
# =============================================================================
# ECS Exec (aws ecs execute-command) のローカル代替 (ecs-exec)
# -----------------------------------------------------------------------------
# 実 AWS では、運用者の手元から次の 1 コマンドで「動いている ECS タスクの中の
# 特定のコンテナ」へ入り、シェルやコマンドを実行できる:
#
#   aws ecs execute-command \
#     --cluster myapp-local-cluster \
#     --task 158d1c8083dd49d6b527399fd6414f5c \
#     --container app-front \
#     --interactive \
#     --command "/bin/bash"
#
# 内部では ECS エージェントがコンテナへ ExecuteCommandAgent (SSM Agent 相当) を
# 差し込み、手元の AWS CLI の session-manager-plugin と SSM の制御/データチャネルで
# つながる。この経路には SCP のようなファイル転送機能が無いため、実運用では
# 「base64 にした中身をコマンド行に載せて送り込む」のが定石になっている。
#
# このスクリプトはその **コマンド体系だけ** をローカル compose に持ち込む。
# チャネルの実体は SSM ではなく `docker exec` (/var/run/docker.sock) だが、
# 利用者から見える入口・引数・出力・エラーは実物にそろえてある。
#
#   aws ecs list-clusters / list-tasks / describe-tasks / execute-command /
#       update-service (--enable-execute-command | --no-enable-execute-command)
#
# さらに、実 ECS Exec でも通用する「base64 をコマンド行に載せる」方式を
# そのまま自動化した補助コマンドを用意している (ファイル投入 / 取り出し):
#
#   ecs-exec put /work/app.war app-front:/opt/server/standalone/deployments/app.war
#   ecs-exec get app-back:/mnt/logs/server.log /work/server.log
#
# 接続先 (frontend / backend など) の定義は tasks.json (★差し替え可能★)。
#
# 【入口は 2 つ】
#   aws       … 実 AWS CLI と同じ書き方をする入口 (ecs サブコマンドのみ偽装)
#   ecs-exec  … 偽装サービス側の補助コマンド (tasks / doctor / shell / run /
#               put / get / sessions)。中では必ず上の execute-command を通す
#
# 【実 AWS との違い (意図的なもの)】
#   - 認証・IAM 権限・SSM チャネルは検査しない (ローカルには存在しないため)
#   - セッションは、呼び出し側に端末があるときだけ pty を張る。実物は常に pty で、
#     バイナリをそのまま流すと壊れる。この偽装では put/get が base64 経由なので
#     どちらでも同じ結果になる
#   - 実 CLI はリモートコマンドの終了コードを返さないが、この偽装は既定で返す
#     (ECS_EXEC_PROPAGATE_EXIT_CODE=0 で実物と同じ「常に 0」にできる)
#   - tasks.json の aliases (frontend / backend) は偽装独自の別名
# =============================================================================
"""ECS Exec (aws ecs execute-command) のローカル代替。"""

from __future__ import annotations

import base64
import binascii
import datetime as _dt
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time

# --- 定数 -------------------------------------------------------------------

# 実 AWS CLI と同じ体裁のバージョン文字列 (偽装であることが分かる印を末尾に付ける)
AWS_CLI_VERSION = (
    "aws-cli/2.31.11 Python/3.12.11 Linux/x86_64 "
    "docker/alpine.3.21 (ecs-exec local mock)"
)

# aws CLI v2 の終了コードに合わせる
EXIT_OK = 0
EXIT_USAGE = 252          # コマンドラインの誤り
EXIT_SERVICE_ERROR = 254  # API がエラーを返した (An error occurred (...) ...)
EXIT_UNSUPPORTED = 2      # この偽装が対応していない操作

TASKS_FILE = os.environ.get("ECS_EXEC_TASKS_FILE", "/etc/ecs-exec/tasks.json")
STATE_FILE = os.environ.get("ECS_EXEC_STATE_FILE", "/var/lib/ecs-exec/state.json")
SESSION_LOG_DIR = os.environ.get("ECS_EXEC_SESSION_LOG_DIR", "/var/log/ecs-exec")
COMPOSE_PROJECT = os.environ.get("ECS_EXEC_COMPOSE_PROJECT", "eap-adot-local")
FILES_DIR = os.environ.get("ECS_EXEC_FILES_DIR", "/work")
# 0 にすると「タスク起動時に execute command を有効化しなかった」状態を再現する
GLOBAL_ENABLED = os.environ.get("ECS_EXEC_ENABLED", "1") != "0"
# 1 にすると session-manager-plugin 未導入のエラーを再現する
SIMULATE_PLUGIN_MISSING = os.environ.get("ECS_EXEC_SIMULATE_PLUGIN_MISSING", "0") == "1"
# 1 にすると偽装側の補足 ([ecs-exec] 行) を stderr へ出す
VERBOSE = os.environ.get("ECS_EXEC_VERBOSE", "0") == "1"
# リモートコマンドの終了コードを返すか (0 にすると実 CLI と同じく常に 0)
PROPAGATE_EXIT_CODE = os.environ.get("ECS_EXEC_PROPAGATE_EXIT_CODE", "1") != "0"
# put の 1 セッションあたりの base64 文字数 (実 ECS Exec の引数長制限を模す)
PUT_CHUNK_CHARS = int(os.environ.get("ECS_EXEC_PUT_CHUNK_CHARS", "16384"))
# get で 1 セッションに載せる最大バイト数 (安全弁)
GET_MAX_BYTES = int(os.environ.get("ECS_EXEC_GET_MAX_BYTES", str(8 * 1024 * 1024)))

BASE64_CHARS = re.compile(r"\A[A-Za-z0-9+/=]*\Z")

# aws CLI のオプションのうち「値を 1 つ取る」もの
_SINGLE_VALUE_OPTS = {
    "cluster", "task", "container", "command", "service", "service-name",
    "desired-status", "launch-type", "family", "started-by", "container-instance",
    "next-token", "max-items", "max-results", "page-size", "starting-token",
    "region", "profile", "output", "query", "endpoint-url", "color",
    "cli-read-timeout", "cli-connect-timeout", "cli-binary-format",
}
# 値を複数取るもの (次の --... まで読む)
_LIST_VALUE_OPTS = {"tasks", "clusters", "include", "services"}
# 値を取らないもの
_FLAG_OPTS = {
    "interactive", "non-interactive", "enable-execute-command",
    "no-enable-execute-command", "no-cli-pager", "no-paginate", "no-verify-ssl",
    "debug", "version", "help", "no-sign-request", "force-new-deployment",
}


# --- 小物 -------------------------------------------------------------------

def note(msg: str) -> None:
    """偽装側の補足を stderr へ (実 AWS CLI は出さないので既定では黙る)。"""
    if VERBOSE:
        sys.stderr.write(f"[ecs-exec] {msg}\n")
        sys.stderr.flush()


def tell(msg: str) -> None:
    """ecs-exec 補助コマンド自身の進行表示 (常に出す)。"""
    sys.stderr.write(f"[ecs-exec] {msg}\n")
    sys.stderr.flush()


def now_iso() -> str:
    return (
        _dt.datetime.now(_dt.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def new_session_id() -> str:
    """実物と同じ体裁のセッション ID (ecs-execute-command-<17 桁>)。"""
    return "ecs-execute-command-" + binascii.hexlify(os.urandom(9)).decode()[:17]


class AwsError(Exception):
    """実 AWS CLI と同じ体裁でエラーを出すための例外。"""

    def __init__(self, code: str, message: str, operation: str):
        super().__init__(message)
        self.code = code
        self.message = message
        self.operation = operation

    def render(self) -> str:
        return (
            f"\nAn error occurred ({self.code}) when calling the "
            f"{self.operation} operation: {self.message}\n"
        )


class UsageError(Exception):
    """コマンドラインの誤り (実 CLI なら argparse 側で弾かれるもの)。"""


# --- tasks.json / 状態 -------------------------------------------------------

def load_registry() -> dict:
    try:
        with open(TASKS_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        raise UsageError(
            f"接続先の定義が見つかりません: {TASKS_FILE}\n"
            "  compose.yaml の ecs-exec サービスで "
            "./compose/ecs-exec/tasks.json をマウントしてください。"
        )
    except json.JSONDecodeError as exc:
        raise UsageError(f"接続先の定義 {TASKS_FILE} の JSON が壊れています: {exc}")


def load_state() -> dict:
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {"services": {}}


def save_state(state: dict) -> None:
    directory = os.path.dirname(STATE_FILE)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, STATE_FILE)


def find_cluster(reg: dict, name: str | None, operation: str) -> dict:
    """クラスター名 (または ARN) を引く。未指定は実物と同じく default 扱い。"""
    wanted = name or "default"
    if wanted.startswith("arn:"):
        wanted = wanted.rsplit("/", 1)[-1]
    for cluster in reg.get("clusters", []):
        if cluster["name"] == wanted:
            return cluster
    raise AwsError("ClusterNotFoundException", "Cluster not found.", operation)


def find_task(cluster: dict, ident: str, operation: str) -> dict:
    """タスク ID / タスク ARN を引く (実物と同じく前方一致は許さない)。"""
    wanted = ident.rsplit("/", 1)[-1] if ident.startswith("arn:") else ident
    for task in cluster.get("tasks", []):
        if task["task_id"] == wanted:
            return task
    raise AwsError(
        "InvalidParameterException", "The referenced task was not found.", operation
    )


def find_container(task: dict, name: str | None, operation: str) -> dict:
    containers = task.get("containers", [])
    if not name:
        if len(containers) == 1:
            return containers[0]
        raise AwsError(
            "InvalidParameterException",
            "Container name must be provided when the task has more than one container.",
            operation,
        )
    for container in containers:
        if container["name"] == name:
            return container
    # 偽装独自の別名 (compose サービス名)。実 AWS では通らない
    for container in containers:
        if name in container.get("aliases", []):
            note(
                f"--container {name} は偽装独自の別名です "
                f"(実 AWS では {container['name']} を指定してください)"
            )
            return container
    raise AwsError(
        "InvalidParameterException", "The container does not exist in the task.", operation
    )


def service_of(cluster: dict, task: dict) -> dict | None:
    for svc in cluster.get("services", []):
        if svc["name"] == task.get("service"):
            return svc
    return None


def exec_enabled(cluster: dict, task: dict) -> bool:
    """実 AWS の enableExecuteCommand (ECS サービス側の設定) 相当。"""
    if not GLOBAL_ENABLED:
        return False
    svc = service_of(cluster, task)
    if svc is None:
        return bool(task.get("enable_execute_command", True))
    key = f"{cluster['name']}/{svc['name']}"
    override = load_state().get("services", {}).get(key)
    if override is not None and "enableExecuteCommand" in override:
        return bool(override["enableExecuteCommand"])
    return bool(svc.get("enable_execute_command", True))


# --- docker (SSM チャネルの代わり) -------------------------------------------

def docker(*args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["docker", *args],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def docker_available() -> tuple[bool, str]:
    proc = docker("version", "--format", "{{.Server.Version}}")
    if proc.returncode != 0:
        return False, proc.stderr.decode(errors="replace").strip()
    return True, "docker engine " + proc.stdout.decode(errors="replace").strip()


def resolve_docker_container(container: dict) -> tuple[str | None, str]:
    """ECS のコンテナ定義 → 実際に動いている docker コンテナ名と状態。

    compose のラベルで引き、見つからなければ tasks.json の docker_container 名で引く。
    戻り値は (コンテナ名 or None, 状態 running/exited/created/absent)。
    """
    svc = container.get("compose_service")
    if svc:
        proc = docker(
            "ps", "-a", "--no-trunc",
            "--filter", f"label=com.docker.compose.project={COMPOSE_PROJECT}",
            "--filter", f"label=com.docker.compose.service={svc}",
            "--format", "{{.Names}}\t{{.State}}",
        )
        if proc.returncode == 0:
            for line in proc.stdout.decode(errors="replace").splitlines():
                if not line.strip():
                    continue
                name, _, state = line.partition("\t")
                return name.strip(), (state.strip() or "unknown")
    name = container.get("docker_container")
    if not name:
        return None, "absent"
    proc = docker("inspect", "-f", "{{.State.Status}}", name)
    if proc.returncode != 0:
        return None, "absent"
    return name, proc.stdout.decode(errors="replace").strip()


def container_times(name: str | None) -> tuple[str, str]:
    """docker から createdAt / startedAt を取り、describe-tasks の体裁にそろえる。"""
    if name:
        proc = docker("inspect", "-f", "{{.Created}}\t{{.State.StartedAt}}", name)
        if proc.returncode == 0:
            created, _, started = proc.stdout.decode(errors="replace").strip().partition("\t")
            return created or now_iso(), started or now_iso()
    stamp = now_iso()
    return stamp, stamp


def exec_agent_status(container: dict, docker_state: str) -> str:
    """ExecuteCommandAgent (SSM Agent 相当) の状態。auto なら docker の状態から導く。"""
    configured = str(container.get("exec_agent", "auto")).upper()
    if configured != "AUTO":
        return configured
    if docker_state == "running":
        return "RUNNING"
    if docker_state in ("created", "restarting"):
        return "PENDING"
    return "STOPPED"


# --- ARN の組み立て ---------------------------------------------------------

def cluster_arn(reg: dict, cluster: dict) -> str:
    return f"arn:aws:ecs:{reg['region']}:{reg['account_id']}:cluster/{cluster['name']}"


def task_arn(reg: dict, cluster: dict, task: dict) -> str:
    return (
        f"arn:aws:ecs:{reg['region']}:{reg['account_id']}:task/"
        f"{cluster['name']}/{task['task_id']}"
    )


def container_arn(reg: dict, cluster: dict, task: dict, container: dict) -> str:
    return (
        f"arn:aws:ecs:{reg['region']}:{reg['account_id']}:container/"
        f"{cluster['name']}/{task['task_id']}/{container.get('container_uuid', '')}"
    )


def taskdef_arn(reg: dict, task_definition: str) -> str:
    return (
        f"arn:aws:ecs:{reg['region']}:{reg['account_id']}:task-definition/{task_definition}"
    )


def service_arn(reg: dict, cluster: dict, svc_name: str) -> str:
    return (
        f"arn:aws:ecs:{reg['region']}:{reg['account_id']}:service/"
        f"{cluster['name']}/{svc_name}"
    )


# --- 出力 (--output / --query) ----------------------------------------------

def apply_query(data, query: str):
    """JMESPath のごく一部だけを解釈する (実 CLI の代用)。

    対応する書き方: name / a.b.c / list[0] / list[*].name / list[].name
    それ以外は誤答を返さないよう UsageError にする。
    """
    current = data
    projected = False  # 直前に [*] / [] を通ったか (以降のキー参照は各要素へ配る)
    for part in query.split("."):
        part = part.strip()
        if not part:
            raise UsageError(f"--query の書式を解釈できません: {query}")
        name, _, rest = part.partition("[")
        if name:
            if projected:
                if not isinstance(current, list):
                    return None
                current = [
                    item.get(name) if isinstance(item, dict) else None for item in current
                ]
            else:
                if not isinstance(current, dict):
                    return None
                current = current.get(name)
        while rest:
            index, _, rest = rest.partition("]")
            index = index.strip()
            rest = rest.lstrip(".")
            if current is None:
                return None
            if index in ("", "*"):
                if projected:
                    # [*][*] のような多段射影は平坦化する ([] と同じ扱い)
                    flat = []
                    for item in current if isinstance(current, list) else []:
                        flat.extend(item if isinstance(item, list) else [item])
                    current = flat
                elif isinstance(current, list):
                    current = list(current)
                else:
                    return None
                projected = True
                continue
            try:
                position = int(index)
            except ValueError:
                raise UsageError(
                    "--query はこの偽装では name / a.b / list[0] / list[*].name "
                    f"だけに対応しています: {query}"
                )
            if not isinstance(current, list) or not (-len(current) <= position < len(current)):
                return None
            current = current[position]
            projected = False
    return current


def to_text(value) -> str:
    """--output text の近似 (スカラーとスカラーの配列は実物と同じ)。"""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "True" if value else "False"
    if isinstance(value, (str, int, float)):
        return str(value)
    if isinstance(value, list):
        return "\n".join(to_text(item) for item in value)
    if isinstance(value, dict):
        return "\t".join(to_text(value[key]) for key in sorted(value))
    return str(value)


def emit(data, output: str, query: str | None) -> None:
    if query:
        data = apply_query(data, query)
    if output == "text":
        rendered = to_text(data)
        if rendered:
            print(rendered)
        return
    if output in ("json", "", None):
        if data is None:
            return
        print(json.dumps(data, ensure_ascii=False, indent=4))
        return
    raise UsageError(f"--output {output} はこの偽装では未対応です (json / text)")


# --- セッション (execute-command の実体) ------------------------------------

class SessionResult:
    def __init__(self, session_id: str, exit_code: int, stdout: bytes, stderr: bytes):
        self.session_id = session_id
        self.exit_code = exit_code
        self.stdout = stdout
        self.stderr = stderr


def write_session_log(
    reg: dict, cluster: dict, task: dict, container: dict, session_id: str,
    display_command: str, docker_name: str, transcript: bytes | None,
    exit_code: int, started_at: float,
) -> str | None:
    """実 ECS Exec の「セッションログ (CloudWatch Logs / S3)」相当をファイルへ残す。

    実物のログストリーム名 <task-id>/<container-name>/<session-id> に合わせて
    ディレクトリを切る。
    """
    if not SESSION_LOG_DIR:
        return None
    try:
        path_dir = os.path.join(SESSION_LOG_DIR, task["task_id"], container["name"])
        os.makedirs(path_dir, exist_ok=True)
        path = os.path.join(path_dir, f"{session_id}.log")
        started_iso = (
            _dt.datetime.fromtimestamp(started_at, _dt.timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z")
        )
        # ファイル投入は base64 をコマンド行に載せるため、そのまま書くと
        # ヘッダが数万文字になる。1 行として読める長さで切る
        if len(display_command) > 500:
            display_command = (
                display_command[:500] + f" …(全 {len(display_command)} 文字を切り詰め)"
            )
        head = (
            f"# sessionId      : {session_id}\n"
            f"# startedAt      : {started_iso}\n"
            f"# cluster        : {cluster['name']}\n"
            f"# taskArn        : {task_arn(reg, cluster, task)}\n"
            f"# container      : {container['name']} "
            f"(compose: {container.get('compose_service')} / docker: {docker_name})\n"
            f"# command        : {display_command}\n"
            f"# exitCode       : {exit_code}\n"
            f"# durationMillis : {int((time.time() - started_at) * 1000)}\n"
            "# ---------------------------------------------------------------\n"
        )
        with open(path, "wb") as fh:
            fh.write(head.encode("utf-8"))
            if transcript is None:
                fh.write("(対話セッションのため本文は記録していない)\n".encode("utf-8"))
            else:
                fh.write(transcript)
        return path
    except OSError as exc:
        note(f"セッションログを書けませんでした: {exc}")
        return None


def run_session(
    reg: dict, cluster: dict, task: dict, container: dict,
    command: str | None = None, *, argv: list[str] | None = None,
    stdin_data: bytes | None = None, capture: bool = False,
    user: str | None = None, operation: str = "ExecuteCommand",
    quiet: bool = False,
) -> SessionResult:
    """execute-command 1 回分。前提条件を実物と同じ順で検査してから docker exec する。

    command  … 実 CLI の --command と同じ 1 本の文字列 (シェルを介さず分解される)
    argv     … 偽装内部から呼ぶとき用。引用の入れ子を避けるため argv を直接渡す
    """
    if not exec_enabled(cluster, task):
        raise AwsError(
            "InvalidParameterException",
            "The execute command failed because execute command was not enabled when "
            "the task was run or the execute command agent isn't running. Wait and try "
            "again or run a new task with execute command enabled and try again.",
            operation,
        )

    docker_name, docker_state = resolve_docker_container(container)
    agent = exec_agent_status(container, docker_state)
    if agent != "RUNNING" or docker_name is None:
        raise AwsError(
            "TargetNotConnectedException",
            "The execute command failed due to an internal error. Try again later.",
            operation,
        )

    if SIMULATE_PLUGIN_MISSING:
        # 実 AWS CLI が session-manager-plugin を見つけられないときの文言
        sys.stderr.write(
            "\nSessionManagerPlugin is not found. Please refer to SessionManager "
            "Documentation here: http://docs.aws.amazon.com/console/systems-manager/"
            "session-manager-plugin-not-found\n"
        )
        raise SystemExit(EXIT_SERVICE_ERROR)

    if argv is None:
        # 実 ECS Exec と同じく、--command はシェルを介さずそのまま起動される。
        # パイプやリダイレクトを使いたいときは sh -c "..." を指定する必要がある
        argv = shlex.split(command or "")
        display_command = command or ""
    else:
        display_command = shlex.join(argv)
    if not argv:
        raise AwsError("InvalidParameterException", "The command cannot be empty.", operation)

    session_id = new_session_id()
    started_at = time.time()

    # 実物は常に pty を張る。ここでは呼び出し側に端末があるときだけ張る
    # (パイプ経由でも中身が壊れないようにするため。docs/ECS-EXEC.md の「違い」参照)
    want_tty = (
        stdin_data is None and not capture
        and sys.stdin.isatty() and sys.stdout.isatty()
    )

    cmd = ["docker", "exec", "-i"]
    if want_tty:
        cmd.append("-t")
    if user:
        cmd += ["-u", user]
    cmd.append(docker_name)
    cmd += argv

    if not quiet:
        sys.stdout.write(
            "\nThe Session Manager plugin was installed successfully. "
            "Use the AWS CLI to start a session.\n\n\n"
            f"Starting session with SessionId: {session_id}\n"
        )
        sys.stdout.flush()

    transcript: bytes | None
    if want_tty:
        proc = subprocess.run(cmd, check=False)
        exit_code, out, err = proc.returncode, b"", b""
        transcript = None
    else:
        proc = subprocess.run(
            cmd,
            input=stdin_data if stdin_data is not None else b"",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        exit_code, out, err = proc.returncode, proc.stdout, proc.stderr
        transcript = out + err
        if not capture:
            sys.stdout.flush()
            sys.stdout.buffer.write(out)
            sys.stdout.buffer.flush()
            sys.stderr.buffer.write(err)
            sys.stderr.buffer.flush()

    if not quiet:
        sys.stdout.write(f"\n\nExiting session with sessionId: {session_id}.\n")
        sys.stdout.flush()

    log_path = write_session_log(
        reg, cluster, task, container, session_id, display_command,
        docker_name, transcript, exit_code, started_at,
    )
    if log_path:
        note(f"セッションログ: {log_path}")
    return SessionResult(session_id, exit_code, out, err)


def sh_session(
    reg, cluster, task, container, script: str, *, user: str | None = None,
    capture: bool = True, quiet: bool = True,
) -> SessionResult:
    """`sh -c '<script>'` を 1 セッションで実行する (偽装内部用)。

    実 ECS Exec で言えば --command "sh -c '<script>'" と同じ。引用の入れ子を
    避けるため、コマンド文字列ではなく argv を組み立てて渡す。
    """
    return run_session(
        reg, cluster, task, container, argv=["sh", "-c", script],
        capture=capture, quiet=quiet, user=user,
    )


# --- aws ecs <operation> -----------------------------------------------------

def op_list_clusters(reg: dict, opts: dict, output: str, query: str | None) -> int:
    emit({"clusterArns": [cluster_arn(reg, c) for c in reg.get("clusters", [])]}, output, query)
    return EXIT_OK


def op_list_tasks(reg: dict, opts: dict, output: str, query: str | None) -> int:
    cluster = find_cluster(reg, opts.get("cluster"), "ListTasks")
    svc_filter = opts.get("service-name")
    desired = (opts.get("desired-status") or "RUNNING").upper()
    arns = []
    for task in cluster.get("tasks", []):
        if svc_filter and task.get("service") != svc_filter:
            continue
        if desired == "STOPPED":
            # この偽装は停止済みタスクを持たない (実物では停止済みの一覧が返る)
            continue
        arns.append(task_arn(reg, cluster, task))
    emit({"taskArns": arns}, output, query)
    return EXIT_OK


def describe_one_task(reg: dict, cluster: dict, task: dict) -> dict:
    containers = []
    all_running = True
    first_docker_name = None
    for container in task.get("containers", []):
        docker_name, docker_state = resolve_docker_container(container)
        first_docker_name = first_docker_name or docker_name
        agent = exec_agent_status(container, docker_state)
        _created, started = container_times(docker_name)
        running = docker_state == "running"
        all_running = all_running and running
        containers.append(
            {
                "containerArn": container_arn(reg, cluster, task, container),
                "taskArn": task_arn(reg, cluster, task),
                "name": container["name"],
                "image": container.get("image", ""),
                "runtimeId": container.get("runtime_id", ""),
                "lastStatus": "RUNNING" if running else "STOPPED",
                "networkBindings": [],
                "networkInterfaces": [
                    {
                        "attachmentId": task.get(
                            "attachment_id", "00000000-0000-0000-0000-000000000000"
                        ),
                        "privateIpv4Address": task.get("private_ip", "10.0.0.10"),
                    }
                ],
                "healthStatus": "HEALTHY" if running else "UNKNOWN",
                "managedAgents": [
                    {
                        "lastStartedAt": started,
                        "name": "ExecuteCommandAgent",
                        "lastStatus": agent,
                    }
                ],
                "cpu": container.get("cpu", "0"),
                "memory": container.get("memory", "0"),
                # ここから下は実 AWS の応答には無い、偽装側の補足キー
                # (どの docker コンテナへつながるのかを追えるようにするため)
                "x-localComposeService": container.get("compose_service"),
                "x-localDockerContainer": docker_name,
                "x-localDockerState": docker_state,
            }
        )

    created, started = container_times(first_docker_name)
    return {
        "attachments": [],
        "availabilityZone": task.get("availability_zone", ""),
        "clusterArn": cluster_arn(reg, cluster),
        "connectivity": "CONNECTED",
        "connectivityAt": created,
        "containers": containers,
        "cpu": task.get("cpu", "0"),
        "createdAt": created,
        "desiredStatus": "RUNNING",
        "enableExecuteCommand": exec_enabled(cluster, task),
        "group": f"service:{task['service']}" if task.get("service") else "",
        "healthStatus": "HEALTHY" if all_running else "UNKNOWN",
        "lastStatus": "RUNNING" if all_running else "PENDING",
        "launchType": task.get("launch_type", "FARGATE"),
        "memory": task.get("memory", "0"),
        "platformFamily": task.get("platform_family", "Linux"),
        "platformVersion": task.get("platform_version", "1.4.0"),
        "startedAt": started,
        "startedBy": f"ecs-svc/{task['service']}" if task.get("service") else "",
        "taskArn": task_arn(reg, cluster, task),
        "taskDefinitionArn": taskdef_arn(reg, task.get("task_definition", "unknown:1")),
        "version": 5,
    }


def op_describe_tasks(reg: dict, opts: dict, output: str, query: str | None) -> int:
    cluster = find_cluster(reg, opts.get("cluster"), "DescribeTasks")
    idents = opts.get("tasks") or []
    if not idents:
        raise UsageError("aws: error: the following arguments are required: --tasks")
    tasks, failures = [], []
    for ident in idents:
        try:
            task = find_task(cluster, ident, "DescribeTasks")
        except AwsError:
            failures.append(
                {
                    "arn": ident if ident.startswith("arn:") else (
                        f"arn:aws:ecs:{reg['region']}:{reg['account_id']}:task/"
                        f"{cluster['name']}/{ident}"
                    ),
                    "reason": "MISSING",
                }
            )
            continue
        tasks.append(describe_one_task(reg, cluster, task))
    emit({"tasks": tasks, "failures": failures}, output, query)
    return EXIT_OK


def op_update_service(reg: dict, opts: dict, output: str, query: str | None) -> int:
    """--enable-execute-command / --no-enable-execute-command だけを偽装する。"""
    cluster = find_cluster(reg, opts.get("cluster"), "UpdateService")
    svc_name = opts.get("service")
    if not svc_name:
        raise UsageError("aws: error: the following arguments are required: --service")
    svc = next((s for s in cluster.get("services", []) if s["name"] == svc_name), None)
    if svc is None:
        raise AwsError("ServiceNotFoundException", "Service not found.", "UpdateService")

    enable = None
    if opts.get("enable-execute-command"):
        enable = True
    if opts.get("no-enable-execute-command"):
        enable = False
    if enable is None:
        raise UsageError(
            "この偽装の update-service は --enable-execute-command / "
            "--no-enable-execute-command だけに対応しています。"
        )

    state = load_state()
    state.setdefault("services", {})[f"{cluster['name']}/{svc_name}"] = {
        "enableExecuteCommand": enable,
        "updatedAt": now_iso(),
    }
    save_state(state)

    tasks = [t for t in cluster.get("tasks", []) if t.get("service") == svc_name]
    emit(
        {
            "service": {
                "serviceArn": service_arn(reg, cluster, svc_name),
                "serviceName": svc_name,
                "clusterArn": cluster_arn(reg, cluster),
                "status": "ACTIVE",
                "desiredCount": len(tasks),
                "runningCount": len(tasks),
                "launchType": "FARGATE",
                "taskDefinition": taskdef_arn(
                    reg, svc.get("task_definition", "unknown:1")
                ),
                "enableExecuteCommand": enable,
                "propagateTags": "NONE",
            }
        },
        output,
        query,
    )
    return EXIT_OK


def op_execute_command(reg: dict, opts: dict, output: str, query: str | None) -> int:
    operation = "ExecuteCommand"
    if opts.get("non-interactive"):
        raise AwsError(
            "InvalidParameterException",
            "Interactive is the only mode supported currently.",
            operation,
        )
    if not opts.get("interactive"):
        raise UsageError(
            "aws: error: the following arguments are required: --interactive\n"
            "  (ECS Exec は対話モードのみ。1 コマンドだけ実行する場合も\n"
            "   --interactive --command \"sh -c 'ls -l'\" のように指定する)"
        )
    command = opts.get("command")
    if not command:
        raise UsageError("aws: error: the following arguments are required: --command")
    if not opts.get("task"):
        raise UsageError("aws: error: the following arguments are required: --task")

    cluster = find_cluster(reg, opts.get("cluster"), operation)
    task = find_task(cluster, opts["task"], operation)
    container = find_container(task, opts.get("container"), operation)

    result = run_session(reg, cluster, task, container, command, operation=operation)
    # 実 CLI はリモートの終了コードを返さない (常に 0)。既定では返す方が便利なので
    # 返し、ECS_EXEC_PROPAGATE_EXIT_CODE=0 のときだけ実物と同じ挙動にする
    return result.exit_code if PROPAGATE_EXIT_CODE else EXIT_OK


ECS_OPERATIONS = {
    "list-clusters": op_list_clusters,
    "list-tasks": op_list_tasks,
    "describe-tasks": op_describe_tasks,
    "execute-command": op_execute_command,
    "update-service": op_update_service,
}


# --- aws CLI の引数解析 ------------------------------------------------------

def parse_aws_args(argv: list[str]) -> tuple[list[str], dict]:
    positional: list[str] = []
    opts: dict = {}
    i = 0
    while i < len(argv):
        token = argv[i]
        if token == "--":
            positional.extend(argv[i + 1:])
            break
        if token.startswith("--"):
            name, sep, inline = token[2:].partition("=")
            if sep:
                opts[name] = inline
                i += 1
                continue
            if name in _FLAG_OPTS:
                opts[name] = True
                i += 1
                continue
            if name in _LIST_VALUE_OPTS:
                values = []
                i += 1
                while i < len(argv) and not argv[i].startswith("--"):
                    values.append(argv[i])
                    i += 1
                opts[name] = values
                continue
            if name in _SINGLE_VALUE_OPTS:
                if i + 1 >= len(argv):
                    raise UsageError(f"aws: error: argument --{name}: expected one argument")
                opts[name] = argv[i + 1]
                i += 2
                continue
            # 知らないオプションは値付きとみなして読み飛ばす
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                opts[name] = argv[i + 1]
                i += 2
            else:
                opts[name] = True
                i += 1
            continue
        positional.append(token)
        i += 1
    return positional, opts


AWS_HELP = """\
この ecs-exec コンテナの `aws` は ECS Exec の偽装です (実 AWS へは接続しません)。

  aws ecs list-clusters
  aws ecs list-tasks       --cluster <cluster> [--service-name <svc>]
  aws ecs describe-tasks   --cluster <cluster> --tasks <task-id> [...]
  aws ecs execute-command  --cluster <cluster> --task <task-id> \\
                           --container <app-front|app-back> \\
                           --interactive --command "<command>"
  aws ecs update-service   --cluster <cluster> --service <svc> \\
                           (--enable-execute-command | --no-enable-execute-command)

共通オプション: --region / --profile / --output json|text / --query <簡易 JMESPath>
ファイル投入などの補助コマンドは `ecs-exec --help` を参照。
"""


def main_aws(argv: list[str]) -> int:
    positional, opts = parse_aws_args(argv)

    if opts.get("version"):
        print(AWS_CLI_VERSION)
        return EXIT_OK
    if opts.get("help") or not positional:
        sys.stdout.write(AWS_HELP)
        return EXIT_OK if opts.get("help") else EXIT_USAGE

    service = positional[0]
    if service != "ecs":
        sys.stderr.write(
            f"この偽装が対応しているのは `aws ecs` だけです (指定: {service})。\n"
            "  実 AWS へは接続しません。対応操作は `aws --help` を参照してください。\n"
        )
        return EXIT_UNSUPPORTED

    operation = positional[1] if len(positional) > 1 else ""
    handler = ECS_OPERATIONS.get(operation)
    if handler is None:
        sys.stderr.write(
            f"`aws ecs {operation or '<operation>'}` はこの偽装では未対応です。\n"
            f"  対応操作: {', '.join(sorted(ECS_OPERATIONS))}\n"
        )
        return EXIT_UNSUPPORTED

    reg = load_registry()
    output = opts.get("output") or os.environ.get("AWS_DEFAULT_OUTPUT") or "json"
    return handler(reg, opts, output, opts.get("query"))


# --- ecs-exec 補助コマンド ---------------------------------------------------

def resolve_target(
    reg: dict, cluster_name: str | None, task_ident: str | None, container_name: str,
    operation: str = "ExecuteCommand",
) -> tuple[dict, dict, dict]:
    """cluster / task を省略したときは tasks.json から一意に決まるものを使う。"""
    if cluster_name:
        cluster = find_cluster(reg, cluster_name, operation)
    else:
        clusters = reg.get("clusters", [])
        if len(clusters) != 1:
            raise UsageError("--cluster を指定してください (定義に複数のクラスターがあります)")
        cluster = clusters[0]
    if task_ident:
        task = find_task(cluster, task_ident, operation)
    else:
        tasks = cluster.get("tasks", [])
        if len(tasks) != 1:
            raise UsageError("--task を指定してください (定義に複数のタスクがあります)")
        task = tasks[0]
    return cluster, task, find_container(task, container_name, operation)


def equivalent_aws_command(cluster: dict, task: dict, container: dict, command: str) -> str:
    return (
        "aws ecs execute-command"
        f" --cluster {cluster['name']}"
        f" --task {task['task_id']}"
        f" --container {container['name']}"
        " --interactive"
        f" --command {shlex.quote(command)}"
    )


def split_remote(spec: str) -> tuple[str, str]:
    """`app-front:/path/to/file` を (コンテナ名, パス) に分ける。"""
    if ":" not in spec:
        raise UsageError(f"コンテナ側は <container>:<path> の形で指定してください (指定: {spec})")
    name, _, path = spec.partition(":")
    if not name or not path:
        raise UsageError(f"コンテナ側の指定が不正です: {spec}")
    return name, path


def remote_sha256(reg, cluster, task, container, path: str, user: str | None) -> str | None:
    """コンテナ内で sha256 を取る (sha256sum → openssl の順に試す)。"""
    quoted = shlex.quote(path)
    for script in (
        f"sha256sum {quoted} 2>/dev/null | cut -d' ' -f1",
        f"openssl dgst -sha256 -r {quoted} 2>/dev/null | cut -d' ' -f1",
    ):
        result = sh_session(reg, cluster, task, container, script, user=user)
        digest = result.stdout.decode(errors="replace").strip()
        if result.exit_code == 0 and re.fullmatch(r"[0-9a-f]{64}", digest):
            return digest
    return None


def cmd_put(args: list[str]) -> int:
    """ローカル → コンテナ。実 ECS Exec でも通る「base64 をコマンド行に載せる」方式。"""
    opts, rest = _parse_helper_args(args)
    if len(rest) != 2:
        raise UsageError("使い方: ecs-exec put <ローカルパス> <container>:<コンテナ内パス>")
    src, spec = rest
    container_name, dest = split_remote(spec)

    if not os.path.isabs(src) and not os.path.exists(src):
        candidate = os.path.join(FILES_DIR, src)
        if os.path.exists(candidate):
            src = candidate
    if not os.path.isfile(src):
        raise UsageError(f"送り込むファイルが見つかりません: {src}")

    with open(src, "rb") as fh:
        payload = fh.read()
    local_digest = hashlib.sha256(payload).hexdigest()
    encoded = base64.b64encode(payload).decode("ascii")
    if not BASE64_CHARS.match(encoded):        # 念のため (シェルへ渡す前の保険)
        raise UsageError("base64 の生成結果が想定外です")

    reg = load_registry()
    cluster, task, container = resolve_target(
        reg, opts.get("cluster"), opts.get("task"), container_name
    )
    user = opts.get("user")
    quoted_dest = shlex.quote(dest)
    tmp_remote = f"/tmp/.ecs-exec-put.{os.getpid()}.{int(time.time())}.b64"
    quoted_tmp = shlex.quote(tmp_remote)
    chunks = [encoded[i:i + PUT_CHUNK_CHARS] for i in range(0, len(encoded), PUT_CHUNK_CHARS)]

    tell(f"{src} ({len(payload)} B, sha256={local_digest[:16]}…) → {container['name']}:{dest}")
    tell(
        f"base64 {len(encoded)} 文字を {max(len(chunks), 1)} セッションに分けて送る "
        f"(1 セッション {PUT_CHUNK_CHARS} 文字まで)"
    )

    if opts.get("parents"):
        parent = os.path.dirname(dest) or "/"
        result = sh_session(
            reg, cluster, task, container, f"mkdir -p {shlex.quote(parent)}", user=user
        )
        if result.exit_code != 0:
            sys.stderr.write(result.stderr.decode(errors="replace"))
            tell(f"NG: 親ディレクトリを作れませんでした: {parent}")
            return 1

    # 空ファイルでも 1 回は流して切り詰める
    if not chunks:
        chunks = [""]
    for index, chunk in enumerate(chunks, start=1):
        redirect = ">" if index == 1 else ">>"
        # base64 の文字種 (A-Za-z0-9+/=) はシェルの特殊文字を含まないため、
        # そのままコマンド行へ載せられる (実 ECS Exec でも同じ手が使える)
        result = sh_session(
            reg, cluster, task, container,
            f"printf %s {chunk} {redirect} {quoted_tmp}", user=user,
        )
        if result.exit_code != 0:
            sys.stderr.write(result.stderr.decode(errors="replace"))
            tell(f"NG: {index} 個目のチャンク送信に失敗 (session={result.session_id})")
            return 1
        tell(f"  chunk {index}/{len(chunks)} ({len(chunk)} 文字) session={result.session_id}")

    result = sh_session(
        reg, cluster, task, container,
        f"base64 -d {quoted_tmp} > {quoted_dest}; rc=$?; rm -f {quoted_tmp}; exit $rc",
        user=user,
    )
    if result.exit_code != 0:
        sys.stderr.write(result.stderr.decode(errors="replace"))
        tell("NG: コンテナ内での base64 デコードに失敗しました")
        return 1

    if opts.get("mode"):
        result = sh_session(
            reg, cluster, task, container,
            f"chmod {shlex.quote(opts['mode'])} {quoted_dest}", user=user,
        )
        if result.exit_code != 0:
            sys.stderr.write(result.stderr.decode(errors="replace"))
            tell(f"WARN: chmod {opts['mode']} に失敗しました")

    remote_digest = remote_sha256(reg, cluster, task, container, dest, user)
    if remote_digest is None:
        tell("WARN: コンテナ内に sha256sum / openssl が無く、内容の照合ができませんでした")
    elif remote_digest != local_digest:
        tell(f"NG: sha256 が一致しません (local={local_digest} remote={remote_digest})")
        return 1
    else:
        tell(f"OK: sha256 一致 ({local_digest})")

    tell("実 AWS で同じことをするときの 1 チャンク分のコマンド:")
    tell("  " + equivalent_aws_command(
        cluster, task, container,
        f"sh -c 'printf %s <base64 チャンク> >> {tmp_remote}'",
    ))
    return 0


def cmd_get(args: list[str]) -> int:
    """コンテナ → ローカル。コンテナ内で base64 にして標準出力で受け取る。"""
    opts, rest = _parse_helper_args(args)
    if len(rest) != 2:
        raise UsageError("使い方: ecs-exec get <container>:<コンテナ内パス> <ローカルパス>")
    spec, dest = rest
    container_name, src = split_remote(spec)

    reg = load_registry()
    cluster, task, container = resolve_target(
        reg, opts.get("cluster"), opts.get("task"), container_name
    )
    user = opts.get("user")
    quoted_src = shlex.quote(src)

    size_result = sh_session(
        reg, cluster, task, container, f"wc -c < {quoted_src}", user=user
    )
    if size_result.exit_code != 0:
        sys.stderr.write(size_result.stderr.decode(errors="replace"))
        tell(f"NG: コンテナ内のファイルを読めません: {src}")
        return 1
    try:
        size = int(size_result.stdout.decode(errors="replace").strip())
    except ValueError:
        size = -1
    if size > GET_MAX_BYTES:
        tell(
            f"NG: {size} B は 1 セッションで運ぶ上限 {GET_MAX_BYTES} B を超えます "
            "(ECS_EXEC_GET_MAX_BYTES で変更できます)"
        )
        return 1

    tell(f"{container['name']}:{src} ({size} B) → {dest}")
    result = sh_session(reg, cluster, task, container, f"base64 {quoted_src}", user=user)
    if result.exit_code != 0:
        sys.stderr.write(result.stderr.decode(errors="replace"))
        tell("NG: コンテナ内での base64 化に失敗しました")
        return 1

    # 実 ECS Exec は pty 経由なので改行や CR が混ざる。取り除いてから復号する
    encoded = re.sub(rb"\s+", b"", result.stdout)
    try:
        payload = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        tell(f"NG: base64 を復号できませんでした: {exc}")
        return 1

    if not os.path.isabs(dest) and os.path.isdir(FILES_DIR):
        dest = os.path.join(FILES_DIR, dest)
    parent = os.path.dirname(dest)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(dest, "wb") as fh:
        fh.write(payload)

    local_digest = hashlib.sha256(payload).hexdigest()
    remote_digest = remote_sha256(reg, cluster, task, container, src, user)
    if remote_digest is None:
        tell("WARN: コンテナ内に sha256sum / openssl が無く、内容の照合ができませんでした")
    elif remote_digest != local_digest:
        tell(f"NG: sha256 が一致しません (remote={remote_digest} local={local_digest})")
        return 1
    else:
        tell(f"OK: sha256 一致 ({local_digest})")
    tell(f"書き出し: {dest} ({len(payload)} B)")
    return 0


def cmd_shell(args: list[str]) -> int:
    opts, rest = _parse_helper_args(args)
    if len(rest) != 1:
        raise UsageError("使い方: ecs-exec shell <container> [--command /bin/bash]")
    reg = load_registry()
    cluster, task, container = resolve_target(
        reg, opts.get("cluster"), opts.get("task"), rest[0]
    )
    command = opts.get("command") or "/bin/bash"
    tell("実行する ECS Exec コマンド:")
    tell("  " + equivalent_aws_command(cluster, task, container, command))
    result = run_session(reg, cluster, task, container, command, user=opts.get("user"))
    return result.exit_code


def cmd_run(args: list[str]) -> int:
    """`ecs-exec run app-front -- ls -l /mnt/logs` の形で 1 コマンドだけ実行する。"""
    opts, rest = _parse_helper_args(args)
    if not rest:
        raise UsageError("使い方: ecs-exec run <container> -- <コマンド...>")
    command = opts.get("command") or shlex.join(rest[1:])
    if not command:
        raise UsageError("実行するコマンドを指定してください (-- のあとに書く)")
    reg = load_registry()
    cluster, task, container = resolve_target(
        reg, opts.get("cluster"), opts.get("task"), rest[0]
    )
    tell("実行する ECS Exec コマンド:")
    tell("  " + equivalent_aws_command(cluster, task, container, command))
    result = run_session(
        reg, cluster, task, container, command,
        quiet=bool(opts.get("quiet")), user=opts.get("user"),
    )
    return result.exit_code


def cmd_tasks(args: list[str]) -> int:
    opts, _rest = _parse_helper_args(args)
    reg = load_registry()
    rows = []
    for cluster in reg.get("clusters", []):
        for task in cluster.get("tasks", []):
            enabled = exec_enabled(cluster, task)
            for container in task.get("containers", []):
                docker_name, docker_state = resolve_docker_container(container)
                rows.append(
                    {
                        "cluster": cluster["name"],
                        "task": task["task_id"],
                        "container": container["name"],
                        "compose": container.get("compose_service", "-"),
                        "docker": docker_name or "-",
                        "state": docker_state,
                        "agent": exec_agent_status(container, docker_state),
                        "enableExecuteCommand": enabled,
                    }
                )
    if opts.get("json"):
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0

    print("ECS Exec の接続先 (tasks.json + docker の実状態)")
    print("")
    header = (
        f"{'CONTAINER':<16}{'COMPOSE':<16}{'DOCKER':<20}{'STATE':<12}{'EXEC AGENT':<12}"
    )
    print(header)
    print("-" * len(header))
    for row in rows:
        print(
            f"{row['container']:<16}{row['compose']:<16}{row['docker']:<20}"
            f"{row['state']:<12}{row['agent']:<12}"
        )
    print("")
    for cluster in reg.get("clusters", []):
        for task in cluster.get("tasks", []):
            print(f"cluster : {cluster['name']}")
            print(f"task    : {task['task_id']}")
            print(f"exec    : enableExecuteCommand={exec_enabled(cluster, task)}")
            print("")
            for container in task.get("containers", []):
                if container["name"] not in ("app-front", "app-back"):
                    continue
                print(f"  # {container['name']} ({container.get('compose_service')}) へ入る")
                print("  " + equivalent_aws_command(cluster, task, container, "/bin/bash"))
                print("")
    return 0


def cmd_sessions(args: list[str]) -> int:
    """記録済みセッションログの一覧 / 表示 (実 ECS Exec のセッションログ保管相当)。"""
    opts, rest = _parse_helper_args(args)
    entries = []
    if os.path.isdir(SESSION_LOG_DIR):
        for root, _dirs, files in os.walk(SESSION_LOG_DIR):
            for name in files:
                if name.endswith(".log"):
                    path = os.path.join(root, name)
                    entries.append((os.path.getmtime(path), path))
    entries.sort(reverse=True)

    if rest and rest[0] == "show":
        if not entries and len(rest) < 2:
            print(f"セッションログがありません ({SESSION_LOG_DIR})")
            return 1
        if len(rest) < 2:
            target = entries[0][1]
        else:
            target = rest[1]
            if not os.path.isfile(target):
                matches = [path for _mtime, path in entries if rest[1] in path]
                if not matches:
                    print(f"該当するセッションログがありません: {rest[1]}")
                    return 1
                target = matches[0]
        with open(target, "rb") as fh:
            sys.stdout.buffer.write(fh.read())
        return 0

    if not entries:
        print(f"セッションログはまだありません ({SESSION_LOG_DIR})")
        return 0
    limit = int(opts.get("limit") or 20)
    for mtime, path in entries[:limit]:
        stamp = _dt.datetime.fromtimestamp(mtime).isoformat(timespec="seconds")
        print(f"{stamp}  {os.path.relpath(path, SESSION_LOG_DIR)}")
    return 0


def cmd_doctor(args: list[str]) -> int:
    """偽装サービス自身と接続先の前提を点検する。"""
    opts, _rest = _parse_helper_args(args)
    self_only = bool(opts.get("self-only"))
    quiet = bool(opts.get("quiet"))
    failures = 0

    def check(label: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        if not ok:
            failures += 1
        if not quiet:
            print(("OK  " if ok else "NG  ") + label + (f" — {detail}" if detail else ""))

    ok, detail = docker_available()
    check("docker ソケット (SSM チャネルの代役)", ok, detail or "/var/run/docker.sock を確認")

    try:
        reg = load_registry()
        check("接続先の定義 tasks.json", True, TASKS_FILE)
    except UsageError as exc:
        check("接続先の定義 tasks.json", False, str(exc).splitlines()[0])
        return 1

    try:
        os.makedirs(SESSION_LOG_DIR, exist_ok=True)
        check("セッションログの出力先", os.access(SESSION_LOG_DIR, os.W_OK), SESSION_LOG_DIR)
    except OSError as exc:
        check("セッションログの出力先", False, str(exc))

    if self_only:
        return 1 if failures else 0

    for cluster in reg.get("clusters", []):
        for task in cluster.get("tasks", []):
            check(
                f"enableExecuteCommand ({cluster['name']}/{task['task_id']})",
                exec_enabled(cluster, task),
                "aws ecs update-service --enable-execute-command で有効化できる",
            )
            for container in task.get("containers", []):
                docker_name, docker_state = resolve_docker_container(container)
                agent = exec_agent_status(container, docker_state)
                check(
                    f"ExecuteCommandAgent: {container['name']}",
                    agent == "RUNNING",
                    f"docker={docker_name or '-'} state={docker_state} agent={agent}",
                )
    if not quiet:
        print("")
        print("実 AWS で同じことをするときの前提 (この偽装では検査しない):")
        print("  - タスクロールに ssmmessages:CreateControlChannel / CreateDataChannel /")
        print("    OpenControlChannel / OpenDataChannel (ecs/iam/task-role-policy.json)")
        print("  - ECS サービス / タスクの enableExecuteCommand が true")
        print("  - 手元の AWS CLI に session-manager-plugin が入っている")
    return 1 if failures else 0


def _parse_helper_args(args: list[str]) -> tuple[dict, list[str]]:
    """ecs-exec 補助コマンド用の簡易パーサ (-- 以降は位置引数として残す)。"""
    opts: dict = {}
    rest: list[str] = []
    flags = {"parents", "json", "quiet", "self-only", "help"}
    single = {"cluster", "task", "container", "command", "user", "mode", "limit"}
    i = 0
    while i < len(args):
        token = args[i]
        if token == "--":
            rest.extend(args[i + 1:])
            break
        if token.startswith("--"):
            name, sep, inline = token[2:].partition("=")
            if sep:
                opts[name] = inline
                i += 1
                continue
            if name in flags:
                opts[name] = True
                i += 1
                continue
            if name in single:
                if i + 1 >= len(args):
                    raise UsageError(f"--{name} には値が必要です")
                opts[name] = args[i + 1]
                i += 2
                continue
            raise UsageError(f"知らないオプションです: --{name}")
        if token == "-p":
            opts["parents"] = True
            i += 1
            continue
        rest.append(token)
        i += 1
    return opts, rest


ECS_EXEC_HELP = """\
ecs-exec — ECS Exec 偽装サービスの補助コマンド
(実行はすべて aws ecs execute-command と同じ経路を通ります)

  ecs-exec tasks [--json]
      接続先 (クラスター / タスク / コンテナ / compose サービス / エージェント状態) と
      そのままコピーできる aws ecs execute-command を表示する

  ecs-exec doctor [--self-only] [--quiet]
      docker ソケット・接続先定義・各コンテナの ExecuteCommandAgent 状態を点検する

  ecs-exec shell <container> [--command /bin/bash]
      対話シェルに入る (例: ecs-exec shell app-front)

  ecs-exec run <container> -- <コマンド...>
      1 コマンドだけ実行する (例: ecs-exec run app-back -- ls -l /mnt/logs)

  ecs-exec put <ローカルパス> <container>:<パス> [-p] [--mode 0644] [--user root]
      ファイルを送り込む (base64 をコマンド行に載せる実運用と同じ方式・sha256 照合つき)

  ecs-exec get <container>:<パス> <ローカルパス> [--user root]
      ファイルを取り出す (コンテナ内で base64 化して受け取る・sha256 照合つき)

  ecs-exec sessions [--limit 20] | ecs-exec sessions show [<セッションIDの一部>]
      記録したセッションログ (実 ECS Exec のセッションログ保管相当) を見る

共通オプション: --cluster <名前> / --task <タスクID>
  (tasks.json のクラスター・タスクが 1 つだけなら省略できる)
<container> は ECS 側のコンテナ名 (app-front / app-back)。tasks.json の
aliases に書いた別名 (frontend / backend) も受け付ける (偽装独自)。
"""

ECS_EXEC_COMMANDS = {
    "tasks": cmd_tasks,
    "doctor": cmd_doctor,
    "shell": cmd_shell,
    "run": cmd_run,
    "put": cmd_put,
    "get": cmd_get,
    "sessions": cmd_sessions,
}


def main_ecs_exec(argv: list[str]) -> int:
    if not argv:
        sys.stdout.write(ECS_EXEC_HELP)
        return EXIT_USAGE
    if argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(ECS_EXEC_HELP)
        return EXIT_OK
    handler = ECS_EXEC_COMMANDS.get(argv[0])
    if handler is None:
        sys.stderr.write(
            f"知らないサブコマンドです: {argv[0]}\n"
            f"  使えるもの: {', '.join(ECS_EXEC_COMMANDS)}\n"
        )
        return EXIT_USAGE
    return handler(argv[1:])


# --- エントリポイント --------------------------------------------------------

def main() -> int:
    argv = sys.argv[1:]
    entry = os.path.basename(sys.argv[0])
    if argv[:1] == ["--entrypoint"]:
        if len(argv) < 2:
            sys.stderr.write("--entrypoint には aws / ecs-exec を指定してください\n")
            return EXIT_USAGE
        entry = argv[1]
        argv = argv[2:]

    try:
        if entry == "aws":
            return main_aws(argv)
        return main_ecs_exec(argv)
    except AwsError as exc:
        sys.stderr.write(exc.render())
        return EXIT_SERVICE_ERROR
    except UsageError as exc:
        sys.stderr.write(f"{exc}\n")
        return EXIT_USAGE
    except BrokenPipeError:
        return EXIT_OK
    except KeyboardInterrupt:
        sys.stderr.write("\n")
        return 130


if __name__ == "__main__":
    sys.exit(main())
