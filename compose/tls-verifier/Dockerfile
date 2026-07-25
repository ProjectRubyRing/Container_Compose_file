# =============================================================================
# tls-verifier — 自己署名証明書 HTTPS 経路の検証コンテナ
# ---------------------------------------------------------------------------
# compose ネットワーク内部から以下を機械的に検証する:
#   1. secure-api が平文 HTTP を受け付けず HTTPS を要求すること
#   2. 自己署名 CA を信頼しないクライアントでは検証が失敗すること (対照実験)
#   3. CA を信頼させれば REST API 呼び出しが成功すること
#   4. app-front / app-back の JVM が (トラストストア取り込み済みのため)
#      secure-api を直接および ALB 経由で呼び出せること
# curl / openssl / jq があれば足りるので alpine ベースの軽量イメージにする。
# =============================================================================
FROM alpine:3.21

RUN apk add --no-cache bash curl openssl jq

COPY verify-tls.sh /usr/local/bin/verify-tls.sh
RUN chmod 0755 /usr/local/bin/verify-tls.sh

ENTRYPOINT ["/usr/local/bin/verify-tls.sh"]
