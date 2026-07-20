# =============================================================================
# lambda-esm — SQS イベントソースマッピング (Event Source Mapping) のローカル代替
# ---------------------------------------------------------------------------
# 実 AWS では Lambda サービスが SQS を裏でロングポーリングし、メッセージが来ると
# 自動で Lambda 関数を起動する ("イベントソースマッピング")。ローカルには
# その仕組みが無いため、この poller がその役割を肩代わりする:
#
#   1. ElasticMQ (sqs コンテナ) を WaitTimeSeconds でロングポーリング
#   2. 受信メッセージを実 SQS イベントと同じ JSON ({"Records":[...]}) に整形
#   3. Lambda ランタイム (RIE) の invoke エンドポイントへ HTTP POST
#        http://lambda:8080/2015-03-31/functions/function/invocations
#   4. Lambda の戻り値 batchItemFailures に含まれない = 成功したメッセージのみ
#      DeleteMessage で削除する (失敗分は可視性タイムアウト後に再処理 → 3回で DLQ)
#
# 依存: boto3 (SQS 呼び出し) / urllib (Lambda invoke, 標準ライブラリ)
# =============================================================================
import json
import os
import time
import urllib.request
import boto3
from botocore.config import Config

# --- 設定 (compose の environment で注入) ---
SQS_ENDPOINT = os.environ.get("SQS_ENDPOINT", "http://sqs:9324")
QUEUE_NAME = os.environ.get("QUEUE_NAME", "app-async-queue")
LAMBDA_INVOKE_URL = os.environ.get(
    "LAMBDA_INVOKE_URL",
    "http://lambda:8080/2015-03-31/functions/function/invocations",
)
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-1")
# 一度に取り出す最大件数 (実 SQS の ReceiveMessage と同じく最大 10)
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "10"))
# ロングポーリング秒数 (実 SQS 最大 20)
WAIT_TIME_SECONDS = int(os.environ.get("WAIT_TIME_SECONDS", "20"))

# ElasticMQ は署名を検証しないが boto3 は必ず署名するためダミー資格情報を渡す
sqs = boto3.client(
    "sqs",
    endpoint_url=SQS_ENDPOINT,
    region_name=AWS_REGION,
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "local"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "local"),
    config=Config(retries={"max_attempts": 3, "mode": "standard"}),
)


def log(msg):
    print(f"[lambda-esm] {msg}", flush=True)


def resolve_queue_url() -> str:
    """キューが作成されるまでリトライしつつ QueueUrl を取得する。"""
    while True:
        try:
            url = sqs.get_queue_url(QueueName=QUEUE_NAME)["QueueUrl"]
            log(f"queue resolved: {url}")
            return url
        except Exception as e:
            log(f"waiting for queue '{QUEUE_NAME}' ... ({type(e).__name__}: {e})")
            time.sleep(3)


def build_sqs_event(messages, queue_url) -> dict:
    """ReceiveMessage の結果を実 SQS イベント ({"Records":[...]}) に整形する。"""
    queue_arn = f"arn:aws:sqs:{AWS_REGION}:000000000000:{QUEUE_NAME}"
    records = []
    for m in messages:
        records.append({
            "messageId": m["MessageId"],
            "receiptHandle": m["ReceiptHandle"],
            "body": m.get("Body", ""),
            "attributes": m.get("Attributes", {}),
            "messageAttributes": m.get("MessageAttributes", {}),
            "md5OfBody": m.get("MD5OfBody", ""),
            "eventSource": "aws:sqs",
            "eventSourceARN": queue_arn,
            "awsRegion": AWS_REGION,
        })
    return {"Records": records}


def invoke_lambda(event: dict) -> dict:
    """Lambda ランタイム (RIE) を HTTP invoke し、戻り値 JSON を返す。"""
    data = json.dumps(event).encode("utf-8")
    req = urllib.request.Request(
        LAMBDA_INVOKE_URL,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read().decode("utf-8", "replace")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        log(f"WARN: non-JSON lambda response: {raw[:300]}")
        return {}


def main():
    log(f"starting. SQS={SQS_ENDPOINT} queue={QUEUE_NAME} lambda={LAMBDA_INVOKE_URL}")
    queue_url = resolve_queue_url()

    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=BATCH_SIZE,
                WaitTimeSeconds=WAIT_TIME_SECONDS,
                AttributeNames=["All"],
                MessageAttributeNames=["All"],
            )
        except Exception as e:
            log(f"receive_message failed: {type(e).__name__}: {e}; retry in 3s")
            time.sleep(3)
            continue

        messages = resp.get("Messages", [])
        if not messages:
            continue  # ロングポーリングのタイムアウト。次のループへ

        log(f"received {len(messages)} message(s); invoking lambda")
        event = build_sqs_event(messages, queue_url)

        try:
            result = invoke_lambda(event)
        except Exception as e:
            # invoke 自体が失敗 → 何も削除しない (可視性タイムアウト後に再処理される)
            log(f"invoke failed: {type(e).__name__}: {e}; messages will be redelivered")
            continue

        # batchItemFailures に載った messageId 以外を削除する
        failed_ids = {f.get("itemIdentifier") for f in result.get("batchItemFailures", [])}
        deleted = 0
        for m in messages:
            if m["MessageId"] in failed_ids:
                continue
            try:
                sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=m["ReceiptHandle"])
                deleted += 1
            except Exception as e:
                log(f"delete_message failed for {m['MessageId']}: {e}")
        log(f"done. deleted={deleted} failed={len(failed_ids)}")


if __name__ == "__main__":
    main()
