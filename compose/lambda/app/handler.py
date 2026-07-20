# =============================================================================
# Lambda 関数 (ローカル代替) — SQS イベントを受け取り、ALB 経由で app-back を POST 呼び出し
# ---------------------------------------------------------------------------
# 配置場所:
#   compose/lambda/app/handler.py  →  コンテナ内 /var/task/handler.py にマウントされる。
#   Lambda ランタイム (RIE) はハンドラを "<ファイル名>.<関数名>" 形式で解決するため、
#   compose の `command: ["handler.lambda_handler"]` がこの lambda_handler を呼ぶ。
#
# 役割 (実 AWS 構成との対応):
#   実 AWS では「SQS → Lambda イベントソースマッピング → Lambda 関数」で自動起動する。
#   ローカルでは lambda-esm コンテナ (poller.py) がイベントソースマッピングの代わりに
#   キューをポーリングし、SQS イベント JSON を組み立ててこの関数を HTTP invoke する。
#   この関数は各レコードの body を取り出し、ALB (nginx) 経由で app-back の
#   Java サーブレット (/async/receive) へ POST する。
#
# 依存ライブラリ:
#   標準ライブラリ (urllib) のみを使用。pip install 不要 = Lambda ベースイメージのまま動く。
# =============================================================================
import json
import os
import urllib.request
import urllib.error

# ALB (nginx) のエンドポイント。compose の environment で上書きする。
# 実 AWS では ALB の DNS 名 (例: internal-xxxx.ap-northeast-1.elb.amazonaws.com)。
ALB_ENDPOINT = os.environ.get("ALB_ENDPOINT", "http://alb:80")

# ALB のリスナールール → ターゲットグループ (app-back) へ流すパス。
# app-back 側 Java サーブレットのコンテキストルート /async + マッピング /receive。
BACK_PATH = os.environ.get("BACK_PATH", "/async/receive")

# app-back への1リクエストのタイムアウト秒数
HTTP_TIMEOUT = float(os.environ.get("HTTP_TIMEOUT_SECONDS", "10"))


def _post_to_back(body: str, message_id: str) -> tuple[int, str]:
    """ALB 経由で app-back の Java サーブレットへ POST し、(HTTPステータス, 応答本文) を返す。"""
    url = ALB_ENDPOINT.rstrip("/") + BACK_PATH
    data = body.encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "X-Source": "lambda-local",          # app-back 側でトレース確認用
            "X-SQS-Message-Id": message_id or "",
        },
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")


def lambda_handler(event, context):
    """
    SQS イベントハンドラ。
    event 形式 (実 SQS イベントと同じ):
        { "Records": [ { "messageId": "...", "body": "...", ... }, ... ] }

    戻り値:
        { "batchItemFailures": [ { "itemIdentifier": "<messageId>" }, ... ] }
        実 SQS の「部分バッチ応答 (ReportBatchItemFailures)」と同じ形式。
        ここに載せた messageId は lambda-esm が削除せず、可視性タイムアウト経過後に
        再処理される (3回失敗で DLQ 行き)。
    """
    records = event.get("Records", [])
    batch_item_failures = []
    results = []

    for record in records:
        message_id = record.get("messageId", "")
        body = record.get("body", "")
        try:
            status, resp_text = _post_to_back(body, message_id)
            if 200 <= status < 300:
                results.append({"messageId": message_id, "status": status})
            else:
                # app-back が 4xx/5xx を返した → このメッセージは失敗扱い (再処理へ)
                batch_item_failures.append({"itemIdentifier": message_id})
                results.append({"messageId": message_id, "status": status, "error": resp_text[:200]})
        except urllib.error.HTTPError as e:
            batch_item_failures.append({"itemIdentifier": message_id})
            results.append({"messageId": message_id, "error": f"HTTPError {e.code}"})
        except Exception as e:  # 接続失敗・タイムアウト等
            batch_item_failures.append({"itemIdentifier": message_id})
            results.append({"messageId": message_id, "error": f"{type(e).__name__}: {e}"})

    # CloudWatch Logs 相当 (ローカルでは docker logs lambda で確認できる)
    print(json.dumps({
        "handler": "lambda_handler",
        "received": len(records),
        "failed": len(batch_item_failures),
        "results": results,
    }, ensure_ascii=False))

    return {"batchItemFailures": batch_item_failures}
