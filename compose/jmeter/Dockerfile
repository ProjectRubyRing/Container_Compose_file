# =============================================================================
# jmeter — Apache JMeter の実行コンテナ (性能試験用)
# ---------------------------------------------------------------------------
# 役割は 1 つだけ:
#   「GUI で作った .jmx を非 GUI (CLI) モードで実行し、GUI で開ける結果を出す」
#
# 使い方の流れ:
#   1. 手元の JMeter GUI でテスト計画を作り、compose/jmeter/test-plans/ へ置く
#   2. docker compose --profile loadtest run --rm jmeter run <plan>.jmx
#   3. compose/jmeter/results/<日時>_<計画名>_<対象>/ に出る result.jtl を
#      手元の JMeter GUI のリスナー (結果をツリーで表示 / 統計レポート 等) で開く
#
# 設計の要点:
#   - JMeter 本体は Apache の配布物 (tgz) をそのまま展開する。ディストリビューション
#     配布のパッケージを使わないのは、GUI 側と**まったく同じバージョン**を選べる
#     ようにするため (jmx / jtl の互換性は同一バージョンが最も確実)。
#   - 偽装本体 (jmeter-run.sh) と設定 (user.properties / targets.json) は
#     compose.yaml から読み取り専用でマウントし直す。直したいときはホスト側の
#     ファイルを編集するだけでよく、イメージの再ビルドは要らない。
#   - Java は front/back と同じ 21 系 (Temurin JRE) にそろえる。
#     JMeter 5.6 系の必要要件は Java 17 以上。
# =============================================================================
# 他の補助コンテナ (tls-verifier / ecs-exec) と同じく alpine ベースにそろえる。
# Debian 系ベースへ差し替えたい場合は JMETER_BASE_IMAGE を上書きする
# (下の RUN は apk / apt-get の双方に対応させてある)。
ARG JMETER_BASE_IMAGE=eclipse-temurin:21-jre-alpine
FROM ${JMETER_BASE_IMAGE}

# ★手元の JMeter GUI と同じバージョンを指定すること (.env の JMETER_VERSION)
ARG JMETER_VERSION=5.6.3
# 配布元。archive.apache.org は旧版も残るためバージョン固定と相性がよい
ARG JMETER_MIRROR=https://archive.apache.org/dist/jmeter/binaries
# 配布物の SHA-512。空なら配布元の .sha512 を取得して突き合わせる。
# 値を固定したい場合 (= 配布元ごと差し替えられても検知したい場合) はここに書く
ARG JMETER_SHA512=""

# JVM_ARGS: 非 GUI 実行では AWT を初期化させない (フォント未導入環境での失敗を避ける)
ENV JMETER_HOME=/opt/apache-jmeter \
    PATH=/opt/apache-jmeter/bin:$PATH \
    JVM_ARGS="-Djava.awt.headless=true"

# bash   … JMeter 同梱の起動スクリプトが使う
# curl   … 配布物の取得
# jq     … targets.json (対象サービス定義) の読み取り
# tzdata … 結果ファイルの時刻を JST で読むため (TZ 環境変数)
RUN set -eux; \
    if command -v apk >/dev/null 2>&1; then \
        apk add --no-cache bash curl ca-certificates jq tzdata; \
    else \
        apt-get update && apt-get install -y --no-install-recommends bash curl ca-certificates jq tzdata && rm -rf /var/lib/apt/lists/*; \
    fi

# --- JMeter 本体 -------------------------------------------------------------
RUN set -eux; \
    tgz="apache-jmeter-${JMETER_VERSION}.tgz"; \
    cd /tmp; \
    curl -fsSL -o "${tgz}" "${JMETER_MIRROR}/${tgz}"; \
    if [ -n "${JMETER_SHA512}" ]; then \
        echo "${JMETER_SHA512}  ${tgz}" > "${tgz}.sha512.expected"; \
    else \
        curl -fsSL -o "${tgz}.sha512.orig" "${JMETER_MIRROR}/${tgz}.sha512"; \
        # 配布元の .sha512 は "<hash>  <filename>" 形式と "<filename>: <hash 4桁区切り>"
        # 形式のどちらもありうるため、16 進 128 文字だけを抜き出して組み立て直す
        hash="$(tr -cd '0-9a-fA-F' < "${tgz}.sha512.orig" | tr 'A-F' 'a-f' | cut -c1-128)"; \
        echo "${hash}  ${tgz}" > "${tgz}.sha512.expected"; \
    fi; \
    sha512sum -c "${tgz}.sha512.expected"; \
    tar -xzf "${tgz}"; \
    mv "apache-jmeter-${JMETER_VERSION}" "${JMETER_HOME}"; \
    rm -f "${tgz}" "${tgz}.sha512.expected" "${tgz}.sha512.orig"; \
    # GUI 専用のドキュメント/サンプルは実行に不要 (イメージを小さく保つ)
    rm -rf "${JMETER_HOME}/docs" "${JMETER_HOME}/printable_docs"; \
    jmeter --version

# --- 偽装本体 (CLI ラッパー) --------------------------------------------------
# compose.yaml から同じパスへマウントし直すので、ここで入れるのは既定値の位置づけ
COPY jmeter-run.sh /opt/jmeter-run/jmeter-run.sh
COPY user.properties /etc/jmeter/user.properties
COPY targets.json /etc/jmeter/targets.json

RUN set -eux; \
    printf '%s\n' \
      '#!/bin/sh' \
      'exec /bin/sh /opt/jmeter-run/jmeter-run.sh "$@"' \
      > /usr/local/bin/jmeter-run; \
    chmod 0755 /usr/local/bin/jmeter-run; \
    mkdir -p /test-plans /results /opt/jmeter-lib-ext

# 実行結果の出力先を作業ディレクトリにする (jmeter.log の既定の出力先でもある)
WORKDIR /results

# `docker compose run --rm jmeter <サブコマンド>` の入口。
# 引数なしのときは既定のテスト計画を実行する (CMD run)
ENTRYPOINT ["/usr/local/bin/jmeter-run"]
CMD ["run"]
