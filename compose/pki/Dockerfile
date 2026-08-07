# =============================================================================
# pki-init — 自己証明書 PKI (自己署名 CA cacert.crt / サーバ証明書) 発行コンテナ
# ---------------------------------------------------------------------------
# alpine には openssl CLI が同梱されないため、ビルド時に追加する
# (実行時 apk add にするとオフライン環境で起動できなくなるため必ずビルド時)。
# 生成した証明書一式は named volume (pki) 経由で他コンテナへ共有する。
# =============================================================================
FROM alpine:3.21

RUN apk add --no-cache openssl

COPY gen-certs.sh /usr/local/bin/gen-certs.sh
RUN chmod 0755 /usr/local/bin/gen-certs.sh

ENTRYPOINT ["/usr/local/bin/gen-certs.sh"]
