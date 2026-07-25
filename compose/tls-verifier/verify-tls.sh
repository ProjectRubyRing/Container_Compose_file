#!/usr/bin/env bash
# =============================================================================
# 自己署名証明書による HTTPS 経路の検証 (compose ネットワーク内部から実行)
# ---------------------------------------------------------------------------
#   docker compose run --rm tls-verifier          全項目を実行
#   docker compose run --rm tls-verifier quick    JVM 経路の確認のみ (短時間)
#
# 検証する経路:
#   (A) tls-verifier → secure-api            HTTPS 直接 (CA 検証あり/なしの対照実験)
#   (B) tls-verifier → ALB(HTTPS) → secure-api  ALB で TLS 終端 → 再暗号化
#   (C) app-front(JVM) → secure-api          ★トラストストア取り込みの本命確認
#   (D) app-back(JVM)  → secure-api          ★同上
#   (E) app-front/back(JVM) → ALB(HTTPS) → secure-api  ★ALB 経由の確認
#
# 期待値どおりなら PASS、そうでなければ FAIL を出力し、FAIL 数を終了コードにする。
# =============================================================================
set -uo pipefail

PKI_DIR="${PKI_DIR:-/pki}"
CA_BUNDLE="${CA_BUNDLE:-${PKI_DIR}/ca/ca-chain.crt}"
ALB_SELFSIGNED_CERT="${ALB_SELFSIGNED_CERT:-${PKI_DIR}/alb/selfsigned/server.crt}"

SECURE_API_HOST="${SECURE_API_HOST:-secure-api}"
SECURE_API_PORT="${SECURE_API_PORT:-8443}"
SECURE_API_BASE="https://${SECURE_API_HOST}:${SECURE_API_PORT}"

ALB_HOST="${ALB_HOST:-alb}"
ALB_HTTPS_PORT="${ALB_HTTPS_PORT:-443}"
ALB_BASE="https://${ALB_HOST}:${ALB_HTTPS_PORT}"

FRONT_PROBE="${FRONT_PROBE:-http://app-front:8080/tls-probe}"
BACK_PROBE="${BACK_PROBE:-http://app-back:8180/tls-probe}"

WAIT_SECONDS="${WAIT_SECONDS:-180}"
MODE="${1:-full}"

PASS=0
FAIL=0

c_ok()   { printf '\033[32m%s\033[0m' "$1"; }
c_ng()   { printf '\033[31m%s\033[0m' "$1"; }
head1()  { echo ""; echo "=============================================================="; echo "$*"; echo "=============================================================="; }
pass()   { PASS=$((PASS + 1)); echo "  [$(c_ok PASS)] $*"; }
fail()   { FAIL=$((FAIL + 1)); echo "  [$(c_ng FAIL)] $*"; }
info()   { echo "  ---- $*"; }

# ---------------------------------------------------------------------------
# 事前チェック: PKI が生成されているか
# ---------------------------------------------------------------------------
head1 "0. PKI (自己署名 CA / サーバ証明書) の生成確認"

for f in "${PKI_DIR}/ca/root-ca.crt" \
         "${PKI_DIR}/ca/intermediate-ca.crt" \
         "${PKI_DIR}/ca/ca-chain.crt" \
         "${PKI_DIR}/secure-api/server.crt" \
         "${PKI_DIR}/secure-api/server.p12" \
         "${PKI_DIR}/alb/selfsigned/server.crt" \
         "${PKI_DIR}/alb/ca-issued/server.crt" \
         "${PKI_DIR}/trust/10-local-test-root-ca.crt" \
         "${PKI_DIR}/trust/20-local-test-intermediate-ca.crt" \
         "${PKI_DIR}/trust/30-alb-selfsigned.crt"; do
  if [[ -r "${f}" ]]; then
    pass "存在する: ${f#${PKI_DIR}/}"
  else
    fail "見つからない: ${f}  (pki-init が失敗している可能性: docker compose logs pki-init)"
  fi
done

if openssl verify -CAfile "${PKI_DIR}/ca/root-ca.crt" \
     -untrusted "${PKI_DIR}/ca/intermediate-ca.crt" \
     "${PKI_DIR}/secure-api/server.crt" >/dev/null 2>&1; then
  pass "証明書チェーン検証: secure-api ← 中間 CA ← ルート CA"
else
  fail "証明書チェーン検証に失敗"
fi

info "secure-api のサーバ証明書:"
openssl x509 -in "${PKI_DIR}/secure-api/server.crt" -noout -subject -issuer 2>/dev/null | sed 's/^/       /'
openssl x509 -in "${PKI_DIR}/secure-api/server.crt" -noout -ext subjectAltName 2>/dev/null | sed 's/^/       /'

# ---------------------------------------------------------------------------
# サービスの起動待ち
# ---------------------------------------------------------------------------
wait_for_tcp() {  # $1=host $2=port $3=label
  local host="$1" port="$2" label="$3" i=0
  while (( i < WAIT_SECONDS )); do
    if timeout 2 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
      return 0
    fi
    i=$((i + 2))
    sleep 2
  done
  echo "  (timeout: ${label} ${host}:${port} が ${WAIT_SECONDS}s 以内に listen しませんでした)"
  return 1
}

wait_for_http() {  # $1=url $2=label
  local url="$1" label="$2" i=0 code
  while (( i < WAIT_SECONDS )); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null)"
    # 200 でなくても「HTTP で応答している」ならデプロイ済みとみなす
    if [[ "${code}" != "000" ]]; then
      return 0
    fi
    i=$((i + 3))
    sleep 3
  done
  echo "  (timeout: ${label} ${url} が ${WAIT_SECONDS}s 以内に応答しませんでした)"
  return 1
}

head1 "1. 依存サービスの起動待ち (最大 ${WAIT_SECONDS}s)"
wait_for_tcp "${SECURE_API_HOST}" "${SECURE_API_PORT}" "secure-api(HTTPS)" \
  && pass "secure-api:${SECURE_API_PORT} が listen" || fail "secure-api:${SECURE_API_PORT} に接続できない"
wait_for_tcp "${ALB_HOST}" "${ALB_HTTPS_PORT}" "alb(HTTPS)" \
  && pass "alb:${ALB_HTTPS_PORT} が listen" || fail "alb:${ALB_HTTPS_PORT} に接続できない"

wait_for_http "${FRONT_PROBE}/truststore" "app-front(tls-probe)" \
  && pass "app-front の tls-probe が応答" || fail "app-front の tls-probe が応答しない"
wait_for_http "${BACK_PROBE}/truststore" "app-back(tls-probe)" \
  && pass "app-back の tls-probe が応答" || fail "app-back の tls-probe が応答しない"

# ---------------------------------------------------------------------------
# (A) tls-verifier → secure-api への直接 HTTPS
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "full" ]]; then
  head1 "2. secure-api は HTTPS を要求する (平文 HTTP は受け付けない)"

  # WireMock を --disable-http で起動しているため 8080 は listen していない。
  # ここで接続できてしまうと「HTTPS 必須」が崩れているので FAIL。
  if timeout 3 bash -c "</dev/tcp/${SECURE_API_HOST}/8080" 2>/dev/null; then
    fail "secure-api:8080 (平文 HTTP) に接続できてしまいました (--disable-http が効いていない)"
  else
    pass "secure-api:8080 (平文 HTTP) は listen していない = HTTPS 必須"
  fi

  # HTTPS ポートへ平文 HTTP で話しかけると当然失敗する
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${SECURE_API_HOST}:${SECURE_API_PORT}/api/v1/ping" 2>/dev/null)"
  if [[ "${code}" == "000" ]]; then
    pass "https ポートへの平文 HTTP 要求は失敗する (期待どおり)"
  else
    fail "https ポートへ平文 HTTP で応答が返りました (status=${code})"
  fi

  head1 "3. 自己署名 CA を信頼しないクライアントでは検証が失敗する (対照実験)"
  # --cacert を渡さない = OS 同梱のパブリック CA だけを信頼する状態。
  # ここが「成功」してしまうと、この後の検証に意味が無くなる。
  out="$(curl -s -S -o /dev/null --max-time 5 "${SECURE_API_BASE}/api/v1/ping" 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    pass "CA 未指定では失敗する (curl rc=${rc})"
    info "${out}"
  else
    fail "CA 未指定なのに成功しました (証明書がパブリック CA 発行になっている?)"
  fi

  head1 "4. 自己署名 CA を信頼すれば REST API を呼び出せる (curl)"
  body="$(curl -s --max-time 10 --cacert "${CA_BUNDLE}" "${SECURE_API_BASE}/api/v1/ping")"
  rc=$?
  if (( rc == 0 )) && echo "${body}" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    pass "GET /api/v1/ping → 200 (JSON: $(echo "${body}" | jq -c .))"
  else
    fail "GET /api/v1/ping に失敗 (rc=${rc}) body=${body}"
  fi

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "${CA_BUNDLE}" \
          "${SECURE_API_BASE}/api/v1/items/ITEM-0001")"
  [[ "${code}" == "200" ]] && pass "GET /api/v1/items/ITEM-0001 → ${code}" \
                           || fail "GET /api/v1/items/ITEM-0001 → ${code}"

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "${CA_BUNDLE}" \
          -X POST -H 'Content-Type: application/json' -d '{"sku":"A-1","qty":2}' \
          "${SECURE_API_BASE}/api/v1/orders")"
  [[ "${code}" == "201" ]] && pass "POST /api/v1/orders → ${code}" \
                           || fail "POST /api/v1/orders → ${code} (期待値 201)"

  head1 "5. secure-api が提示する証明書チェーン (openssl s_client)"
  info "サーバが提示したチェーン:"
  echo | openssl s_client -connect "${SECURE_API_HOST}:${SECURE_API_PORT}" \
          -servername "${SECURE_API_HOST}" -CAfile "${CA_BUNDLE}" 2>/dev/null \
    | sed -n '/Certificate chain/,/---/p' | sed 's/^/       /'
  verify_line="$(echo | openssl s_client -connect "${SECURE_API_HOST}:${SECURE_API_PORT}" \
                   -servername "${SECURE_API_HOST}" -CAfile "${CA_BUNDLE}" 2>/dev/null \
                 | grep 'Verify return code')"
  if echo "${verify_line}" | grep -q '0 (ok)'; then
    pass "openssl 検証結果:${verify_line#*:}"
  else
    fail "openssl 検証に失敗:${verify_line:-(取得できず)}"
  fi
fi

# ---------------------------------------------------------------------------
# (B) tls-verifier → ALB(HTTPS) → secure-api
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "full" ]]; then
  head1 "6. ALB の HTTPS リスナー (証明書適用済み) 経由で REST API を呼ぶ"

  # ALB がどちらの証明書を適用中かを判定する (自己署名 or 中間 CA 発行)。
  alb_issuer="$(echo | openssl s_client -connect "${ALB_HOST}:${ALB_HTTPS_PORT}" \
                  -servername "${ALB_HOST}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
  alb_subject="$(echo | openssl s_client -connect "${ALB_HOST}:${ALB_HTTPS_PORT}" \
                  -servername "${ALB_HOST}" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"
  info "ALB が提示した証明書: ${alb_subject}"
  info "                     ${alb_issuer}"

  if echo "${alb_issuer}" | grep -q "Intermediate CA"; then
    ALB_TRUST_ARG=(--cacert "${CA_BUNDLE}")
    info "→ 中間 CA 発行パターン。CA バンドルで検証します"
  else
    ALB_TRUST_ARG=(--cacert "${ALB_SELFSIGNED_CERT}")
    info "→ 自己署名パターン。その証明書自体を信頼して検証します"
  fi

  body="$(curl -s --max-time 10 "${ALB_TRUST_ARG[@]}" "${ALB_BASE}/secure/v1/ping")"
  rc=$?
  if (( rc == 0 )) && echo "${body}" | jq -e '.status == "ok"' >/dev/null 2>&1; then
    pass "ALB(HTTPS) → secure-api(HTTPS 再暗号化) → 200"
    info "$(echo "${body}" | jq -c .)"
  else
    fail "ALB 経由の REST 呼び出しに失敗 (rc=${rc}) body=${body}"
  fi

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${ALB_TRUST_ARG[@]}" "${ALB_BASE}/healthz")"
  [[ "${code}" == "200" ]] && pass "ALB HTTPS リスナーのヘルスチェック /healthz → ${code}" \
                           || fail "ALB HTTPS リスナー /healthz → ${code}"
fi

# ---------------------------------------------------------------------------
# (C)(D)(E) front / back の JVM から呼ぶ ★本命
# ---------------------------------------------------------------------------
head1 "7. app-front / app-back の JVM トラストストア確認"

for pair in "app-front|${FRONT_PROBE}" "app-back|${BACK_PROBE}"; do
  name="${pair%%|*}"; base="${pair##*|}"
  ts="$(curl -s --max-time 10 "${base}/truststore")"
  if echo "${ts}" | jq -e '.readable == true' >/dev/null 2>&1; then
    total="$(echo "${ts}" | jq -r '.totalEntries')"
    path="$(echo "${ts}" | jq -r '.trustStore')"
    imported="$(echo "${ts}" | jq -r '.importedForThisTest | length' 2>/dev/null)"
    # jq が失敗しても算術評価でエラーにならないよう既定値を入れる
    [[ "${imported}" =~ ^[0-9]+$ ]] || imported=0
    if (( imported > 0 )); then
      pass "${name}: トラストストア ${path} (全 ${total} 件 / 本検証で追加 ${imported} 件)"
      echo "${ts}" | jq -r '.importedForThisTest[] | "         + " + .'
    else
      fail "${name}: 検証用の証明書がトラストストアに入っていません (entrypoint の取り込みを確認)"
    fi
  else
    fail "${name}: トラストストア情報を取得できません → ${ts}"
  fi
done

head1 "8. ★front/back の JVM から HTTPS REST API を呼び出せるか (直接)"

check_probe() {  # $1=表示名 $2=probe base $3=target
  local name="$1" base="$2" target="$3" res ok status url tlsproto peer
  res="$(curl -s --max-time 20 "${base}/check?target=${target}")"
  ok="$(echo "${res}" | jq -r '.ok // false' 2>/dev/null)"
  url="$(echo "${res}" | jq -r '.url // "?"' 2>/dev/null)"
  if [[ "${ok}" == "true" ]]; then
    status="$(echo "${res}" | jq -r '.httpStatus')"
    tlsproto="$(echo "${res}" | jq -r '.tls.protocol // "?"')"
    peer="$(echo "${res}" | jq -r '.tls.peerSubject // "?"')"
    pass "${name} → ${url} : HTTP ${status} / ${tlsproto}"
    info "相手証明書: ${peer}"
    info "応答: $(echo "${res}" | jq -r '.responseBody' | tr -d '\n' | cut -c1-160)"
  else
    fail "${name} → ${url} : 失敗"
    echo "${res}" | jq -r '.error | "         type: " + .type, "         msg : " + .message, "         hint: " + .hint' 2>/dev/null \
      || echo "         raw: ${res}"
  fi
}

check_probe "app-front(JVM)" "${FRONT_PROBE}" "direct"
check_probe "app-back(JVM)"  "${BACK_PROBE}"  "direct"

head1 "9. ★front/back の JVM から ALB(HTTPS) 経由で REST API を呼び出せるか"

check_probe "app-front(JVM)→ALB" "${FRONT_PROBE}" "alb"
check_probe "app-back(JVM)→ALB"  "${BACK_PROBE}"  "alb"

# ---------------------------------------------------------------------------
# まとめ
# ---------------------------------------------------------------------------
head1 "結果: PASS=${PASS} FAIL=${FAIL}"
if (( FAIL == 0 )); then
  echo "  すべての検証に成功しました。"
  echo "  - secure-api は HTTPS のみを受け付け、自己署名 CA 発行の証明書を提示している"
  echo "  - front/back の JVM は取り込んだ CA / 自己署名証明書で検証に成功している"
  echo "  - ALB(HTTPS) 経由でも同じ REST API を呼び出せている"
  exit 0
else
  echo "  ${FAIL} 件の検証に失敗しました。上の FAIL 行を確認してください。"
  echo "  よくある原因:"
  echo "   - pki-init が未実行 / 証明書が古い  → docker compose run --rm -e PKI_FORCE_REGENERATE=1 pki-init --oneshot"
  echo "   - front/back が証明書取り込み前に起動 → docker compose restart app-front app-back"
  echo "   - ALB の証明書切り替え直後で reload 未実行 → ./alb-tls-cert.sh status"
  exit "${FAIL}"
fi
