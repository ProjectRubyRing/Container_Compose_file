#!/usr/bin/env bash
# =============================================================================
# 自己証明書 (cacert.crt) HTTPS 経路 (secure-api / ALB HTTPS リスナー) の動作確認
#   詳細は docs/TLS-SELF-SIGNED-ALB.md を参照
# ---------------------------------------------------------------------------
#   ./verify-tls.sh          コンテナ内検証 + ホストからの検証
#   ./verify-tls.sh quick    コンテナ内検証のみ (JVM 経路のみ・短時間)
#   ./verify-tls.sh host     ホストからの検証のみ
#
# 検証の主眼:
#   1. secure-api は HTTPS を要求する (平文 HTTP を受け付けない)
#   2. 自己証明書 cacert.crt を信頼しないクライアントは検証に失敗する (対照実験)
#   3. frontend / backend は cacert.crt を JDK と JBoss(Elytron) の両方の
#      トラストストアへ取り込んでいるため、どちらの経路でも REST API 呼び出しに成功する
#   4. ALB (HTTPS リスナー) 経由でも同じ REST API を呼び出せる
# =============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-all}"
# ホスト側検証で使う CA を取り出す先 (git 管理外)
OUT_DIR="${DIR}/.pki-out"

run_in_network() {
  echo "##############################################################"
  echo "# コンテナ内 (compose ネットワーク) からの検証"
  echo "##############################################################"
  if [[ "${MODE}" == "quick" ]]; then
    docker compose run --rm tls-verifier quick
  else
    docker compose run --rm tls-verifier
  fi
  return $?
}

run_from_host() {
  echo ""
  echo "##############################################################"
  echo "# ホスト (localhost 公開ポート) からの検証"
  echo "#   secure-api : https://localhost:8543"
  echo "#   ALB(HTTPS) : https://localhost:9443"
  echo "##############################################################"

  if ! command -v curl >/dev/null 2>&1; then
    echo "SKIP: curl が無いためホストからの検証をスキップします"
    return 0
  fi

  mkdir -p "${OUT_DIR}"
  # コンテナ内の named volume から取り出す:
  #   cacert.crt        ★受領した (もしくは自動発行された) 自己証明書そのもの
  #   verify-bundle.crt  サーバ証明書を検証できる CA バンドル
  #                      (受領物が鍵なしの場合は cacert.crt + local-test-ca.crt)
  if ! docker compose exec -T pki-init cat /pki/ca/cacert.crt > "${OUT_DIR}/cacert.crt" 2>/dev/null; then
    echo "WARN: pki-init から cacert.crt を取り出せません (docker compose up -d 済みか確認してください)"
    return 1
  fi
  docker compose exec -T pki-init cat /pki/ca/verify-bundle.crt > "${OUT_DIR}/verify-bundle.crt" 2>/dev/null
  docker compose exec -T pki-init cat /pki/alb/selfsigned/server.crt > "${OUT_DIR}/alb-selfsigned.crt" 2>/dev/null

  echo "自己証明書を ${OUT_DIR}/cacert.crt へ取り出しました (ブラウザや他ツールでの検証にも使えます)"
  if command -v openssl >/dev/null 2>&1; then
    echo "  SHA-256: $(openssl x509 -in "${OUT_DIR}/cacert.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
    echo "  subject: $(openssl x509 -in "${OUT_DIR}/cacert.crt" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    # 受領物だけでサーバ証明書を検証できるか (鍵なし受領時は検証できないのが正しい)
    if ! cmp -s "${OUT_DIR}/cacert.crt" "${OUT_DIR}/verify-bundle.crt"; then
      echo "  NOTE: 受領した cacert.crt には秘密鍵が無いため、サーバ証明書は local-test-ca が"
      echo "        発行しています。ホストからの検証には verify-bundle.crt を使います"
      echo "        (受領物で確認できるのは front/back のトラストストア取り込みまで)"
    fi
  fi
  echo ""

  echo "--- 1. secure-api へ CA 未指定で HTTPS (失敗が期待値) ---"
  if curl -s -S -o /dev/null --max-time 5 "https://localhost:8543/api/v1/ping" 2>&1; then
    echo "  NG: CA 未指定なのに成功しました"
  else
    echo "  OK: 期待どおり検証に失敗しました (自己証明書は既定では信頼されない)"
  fi

  echo "--- 2. secure-api へ CA 指定で HTTPS REST 呼び出し (成功が期待値) ---"
  curl -s -w "\n  (status: %{http_code})\n" --max-time 10 \
    --cacert "${OUT_DIR}/verify-bundle.crt" \
    "https://localhost:8543/api/v1/ping" \
    | sed 's/^/  /' \
    || echo "  NG: 呼び出しに失敗しました"

  echo "--- 3. secure-api が平文 HTTP を受け付けないこと (失敗が期待値) ---"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:8543/api/v1/ping" 2>/dev/null)"
  if [[ "${code}" == "000" ]]; then
    echo "  OK: 平文 HTTP では応答しません (HTTPS 必須)"
  else
    echo "  NG: 平文 HTTP に応答しました (status=${code})"
  fi

  echo "--- 4. ALB (HTTPS リスナー) が提示する証明書 ---"
  if command -v openssl >/dev/null 2>&1; then
    echo | openssl s_client -connect localhost:9443 -servername alb 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /' \
      || echo "  WARN: ALB へ接続できません"
  else
    echo "  SKIP: openssl が無いため証明書表示をスキップ"
  fi

  echo "--- 5. ALB(HTTPS) 経由で secure-api の REST を呼ぶ (成功が期待値) ---"
  # 適用中の証明書 (自己署名リーフ / CA 発行) のどちらでも検証できるよう両方渡す
  cat "${OUT_DIR}/verify-bundle.crt" "${OUT_DIR}/alb-selfsigned.crt" > "${OUT_DIR}/alb-trust.crt" 2>/dev/null
  curl -s -w "\n  (status: %{http_code})\n" --max-time 10 \
    --cacert "${OUT_DIR}/alb-trust.crt" --resolve "alb:9443:127.0.0.1" \
    "https://alb:9443/secure/v1/ping" \
    | sed 's/^/  /' \
    || echo "  NG: ALB 経由の呼び出しに失敗しました"
  echo "  (--resolve で 'alb' を 127.0.0.1 に解決させています。証明書の SAN が"
  echo "   DNS:alb のため、localhost で叩くとホスト名不一致になります)"

  echo "--- 6. frontend / backend の JVM 経路 (ホスト公開ポート経由) ---"
  # trust=jdk  … JDK 同梱 cacerts のコピー + cacert.crt (JVM 既定の SSLContext)
  # trust=jboss… JBoss(Elytron) の jboss-truststore.p12 (cacert.crt のみ)
  for pair in "frontend|http://localhost:8080/tls-probe" "backend|http://localhost:8180/tls-probe"; do
    name="${pair%%|*}"; base="${pair##*|}"
    for trust in jdk jboss; do
      echo "  [${name}] 直接 (trust=${trust}):"
      curl -s --max-time 20 "${base}/check?target=direct&trust=${trust}" | sed 's/^/    /' || echo "    NG"
      echo "  [${name}] ALB 経由 (trust=${trust}):"
      curl -s --max-time 20 "${base}/check?target=alb&trust=${trust}" | sed 's/^/    /' || echo "    NG"
    done
  done
}

rc=0
case "${MODE}" in
  quick)
    run_in_network; rc=$?
    ;;
  host)
    run_from_host; rc=$?
    ;;
  all)
    run_in_network; rc=$?
    run_from_host
    ;;
  *)
    echo "usage: $0 {all|quick|host}" >&2
    exit 1
    ;;
esac

echo ""
echo "=============================================================="
if (( rc == 0 )); then
  echo "検証完了: コンテナ内の検証はすべて PASS しました。"
else
  echo "検証完了: コンテナ内の検証に ${rc} 件の FAIL があります。上のログを確認してください。"
fi
echo ""
echo "参考:"
echo "  受領した cacert.crt の投入 : compose/pki/provided/cacert.crt に置いて"
echo "                               docker compose restart pki-init secure-api alb mysql frontend backend"
echo "                               (置き場を変える場合は .env の PKI_PROVIDED_DIR)"
echo "  cacert.crt の出力と配置    : compose/pki/export/ に自動出力される。./pki-export.sh で取り出し/配置"
echo "                               ビルドへ渡す: docker compose -f compose.yaml -f compose.build-secret.yaml build frontend backend"
echo "                               受領物に固定: ./pki-export.sh --to-provided"
echo "  どのモードで動いたか       : docker compose logs pki-init | grep 'MODE:'"
echo "  ALB の証明書を切り替える : ./alb-tls-cert.sh selfsigned | ca-issued | status"
echo "  証明書を作り直す         : docker compose run --rm -e PKI_FORCE_REGENERATE=1 pki-init --oneshot"
echo "                             (その後 docker compose restart frontend backend alb secure-api)"
echo "  トラストストアの中身     : curl -s http://localhost:8080/tls-probe/truststore"
echo "                             (JDK 側 / JBoss 側の両方が stores.jdk / stores.jboss に出ます)"
echo "=============================================================="
exit "${rc}"
