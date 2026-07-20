# =============================================================================
# lambda-esm コンテナ (SQS イベントソースマッピングのローカル代替) 用イメージ
# ---------------------------------------------------------------------------
# 軽量な python イメージに boto3 だけ入れて poller.py を実行する。
# =============================================================================
FROM python:3.12-slim

# boto3 = SQS 呼び出し用。urllib は標準ライブラリ (Lambda invoke に使用)。
RUN pip install --no-cache-dir "boto3==1.34.162"

WORKDIR /app
COPY poller.py /app/poller.py

# バッファリングを無効化して docker logs に即時反映
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/poller.py"]
