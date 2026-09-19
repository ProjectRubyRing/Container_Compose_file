#!/bin/sh
# =============================================================================
# jmeter-run — JMeter 実行コンテナの入口 (非 GUI 実行と結果出力のラッパー)
# ---------------------------------------------------------------------------
# 何をするか:
#   1. test-plans/ に置かれた .jmx を選ぶ
#   2. targets.json から「どのサービスへ投げるか」(既定 frontend) を引き、
#      ホスト名 / ポート / プロトコル / パスを -J プロパティとして渡す
#   3. JMeter を非 GUI (-n) で実行し、1 回の実行につき 1 つのディレクトリへ
#      結果一式 (jtl / log / HTML レポート / 実行条件) を出力する
#
# なぜ非 GUI なのか:
#   GUI 実行は描画とリスナー保持に CPU とヒープを使い、負荷をかける側が先に
#   詰まる。Apache 自身が「試験本番は必ず非 GUI、GUI は計画作成と結果参照だけ」
#   としている。このコンテナはその「試験本番」側だけを担う。
#
# 使い方:
#   docker compose --profile loadtest run --rm jmeter run [PLAN.jmx] [-- <jmeter の追加引数>]
#   docker compose --profile loadtest run --rm jmeter list
#   docker compose --profile loadtest run --rm jmeter targets
#   docker compose --profile loadtest run --rm jmeter doctor
#   docker compose --profile loadtest run --rm jmeter report <結果ディレクトリ名>
#   docker compose --profile loadtest run --rm jmeter clean [--days N | --all]
#   docker compose --profile loadtest run --rm jmeter exec --version   # 素の jmeter
# =============================================================================
set -eu

# --- 既定値 (compose.yaml の environment: で上書きする) ----------------------
JMETER_PLANS_DIR="${JMETER_PLANS_DIR:-/test-plans}"
JMETER_RESULTS_DIR="${JMETER_RESULTS_DIR:-/results}"
JMETER_TARGETS_FILE="${JMETER_TARGETS_FILE:-/etc/jmeter/targets.json}"
JMETER_USER_PROPERTIES="${JMETER_USER_PROPERTIES:-/etc/jmeter/user.properties}"
JMETER_LIB_EXT="${JMETER_LIB_EXT:-/opt/jmeter-lib-ext}"
JMETER_TRUST_DIR="${JMETER_TRUST_DIR:-/mnt/pki/trust}"
JMETER_TARGET="${JMETER_TARGET:-}"
JMETER_PLAN="${JMETER_PLAN:-}"
JMETER_RESULTS_FORMAT="${JMETER_RESULTS_FORMAT:-csv}"
JMETER_SAVE_RESPONSE_DATA="${JMETER_SAVE_RESPONSE_DATA:-false}"
JMETER_GENERATE_REPORT="${JMETER_GENERATE_REPORT:-true}"
JMETER_PRECHECK="${JMETER_PRECHECK:-true}"
JMETER_MAX_ERROR_RATE="${JMETER_MAX_ERROR_RATE:-}"
JMETER_HEAP="${JMETER_HEAP:-}"
JMETER_PROPS="${JMETER_PROPS:-}"
JMETER_RUN_NAME="${JMETER_RUN_NAME:-}"

log() { printf '[jmeter-run] %s\n' "$*" >&2; }
die() { printf '[jmeter-run] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
# targets.json の読み取り
#   実 ECS ではサービス間は VPC 内のホスト名で繋がる。compose でも同じ形
#   (サービス名 = ホスト名) なので、この表は実質「ポートとパスの早見表」になる。
# -----------------------------------------------------------------------------
targets_json() {
    [ -f "$JMETER_TARGETS_FILE" ] || die "targets.json が無い: $JMETER_TARGETS_FILE"
    cat "$JMETER_TARGETS_FILE"
}

target_names() {
    targets_json | jq -r '.targets | keys[]'
}

default_target() {
    targets_json | jq -r '.default // "frontend"'
}

target_field() {
    # $1: 対象名, $2: フィールド名
    targets_json | jq -r --arg n "$1" --arg f "$2" '.targets[$n][$f] // empty'
}

resolve_target() {
    name="${1:-}"
    [ -n "$name" ] || name="$(default_target)"
    if [ "$(targets_json | jq -r --arg n "$name" '.targets | has($n)')" != "true" ]; then
        log "対象 '$name' は targets.json に無い。使える対象:"
        target_names | sed 's/^/  - /' >&2
        die "対象名が不正 (JMETER_TARGET / --target で指定する)"
    fi
    printf '%s' "$name"
}

# -----------------------------------------------------------------------------
# テスト計画の解決
#   引数 > JMETER_PLAN > test-plans/ に 1 つだけあればそれ > 同梱サンプル
# -----------------------------------------------------------------------------
resolve_plan() {
    plan="${1:-}"
    [ -n "$plan" ] || plan="$JMETER_PLAN"

    if [ -z "$plan" ]; then
        count="$(find "$JMETER_PLANS_DIR" -maxdepth 1 -name '*.jmx' -type f 2>/dev/null | wc -l)"
        if [ "$count" -eq 1 ]; then
            plan="$(find "$JMETER_PLANS_DIR" -maxdepth 1 -name '*.jmx' -type f)"
        elif [ -f "$JMETER_PLANS_DIR/sample-frontend.jmx" ]; then
            plan="$JMETER_PLANS_DIR/sample-frontend.jmx"
            log "テスト計画を指定していないため同梱サンプルを使う: sample-frontend.jmx"
        elif [ "$count" -eq 0 ]; then
            die "テスト計画が 1 つも無い。GUI で作った .jmx を compose/jmeter/test-plans/ へ置くこと"
        else
            log "テスト計画が複数ある。ファイル名を引数で指定すること:"
            cmd_list >&2
            die "テスト計画が未指定"
        fi
    fi

    # ファイル名だけでも、plans ディレクトリからの相対パスでも受け付ける
    case "$plan" in
        /*) : ;;
        *) plan="$JMETER_PLANS_DIR/$plan" ;;
    esac
    [ -f "$plan" ] || die "テスト計画が見つからない: $plan"
    printf '%s' "$plan"
}

# -----------------------------------------------------------------------------
# 自己証明書 (cacert.crt) を JMeter の JVM トラストストアへ取り込む
#   front/back の entrypoint.sh と同じ考え方。HTTPS の対象 (alb-https /
#   secure-api) を叩くとき、これが無いと PKIX path building failed になる。
# -----------------------------------------------------------------------------
build_truststore() {
    ts=/tmp/jmeter-truststore.p12
    [ -d "$JMETER_TRUST_DIR" ] || return 0
    set -- "$JMETER_TRUST_DIR"/*.crt
    [ -f "$1" ] || return 0

    rm -f "$ts"
    n=0
    for crt in "$@"; do
        alias="$(basename "$crt" .crt)"
        if keytool -importcert -noprompt -trustcacerts \
            -alias "$alias" -file "$crt" \
            -keystore "$ts" -storetype PKCS12 -storepass changeit >/dev/null 2>&1; then
            n=$((n + 1))
        else
            log "警告: トラストストアへの取り込みに失敗: $crt"
        fi
    done
    if [ -f "$ts" ]; then
        log "トラストストアを生成: $ts (証明書 $n 件)"
        printf '%s' "$ts"
    fi
}

# -----------------------------------------------------------------------------
# 対象への到達確認 (試験の空振り防止)
#   JMeter は接続できなくてもエラーとして淡々と流し続ける。10 分走らせてから
#   「全部 Connection refused だった」を避けるため、開始前に 1 回だけ確認する。
# -----------------------------------------------------------------------------
precheck() {
    url="$1"
    [ "$JMETER_PRECHECK" = "true" ] || return 0
    if curl -sk -o /dev/null --connect-timeout 5 --max-time 10 "$url"; then
        log "到達確認 OK: $url"
    else
        log "警告: 到達確認に失敗: $url"
        log "  対象サービスが起動しているか確認する (docker compose ps)。"
        log "  frontend / backend は起動完了まで 2〜3 分かかる (start_period 120s)。"
        log "  確認を省略するには JMETER_PRECHECK=false を指定する。"
        die "対象へ到達できないため試験を開始しない"
    fi
}

# -----------------------------------------------------------------------------
# 一次集計 (summary-stats.txt を書き、エラー率 (%) を標準出力へ返す)
#   $1: jtl, $2: HTML レポートのディレクトリ, $3: 出力先ディレクトリ
#
#   値の出どころは HTML レポートと同じ statistics.json を第一候補にする。
#   両者で数字が食い違うと「どちらが正か」で必ず揉めるため。
#   レポートを生成していない場合だけ jtl を直接読む。その際、jtl の CSV は
#   フィールド内にカンマを含むことがある (トランザクションコントローラの
#   responseMessage が "Number of samples in transaction : 1, ..." になる)
#   ので、素朴なカンマ分割ではなく引用符を解釈して分割する。
# -----------------------------------------------------------------------------
compute_stats() {
    jtl="$1"
    rep="$2"
    out="$3"

    if [ -f "$rep/statistics.json" ]; then
        jq -r '.Total |
            "サンプル数   : \(.sampleCount)",
            "エラー       : \(.errorCount) (\(if .sampleCount > 0 then (.errorCount * 10000 / .sampleCount | round / 100) else 0 end)%)",
            "平均応答     : \(.meanResTime * 10 | round / 10) ms",
            "90%ile       : \(.pct1ResTime * 10 | round / 10) ms",
            "95%ile       : \(.pct2ResTime * 10 | round / 10) ms",
            "99%ile       : \(.pct3ResTime * 10 | round / 10) ms",
            "最大応答     : \(.maxResTime * 10 | round / 10) ms",
            "スループット : \(.throughput * 100 | round / 100) req/s"
        ' "$rep/statistics.json" > "$out/summary-stats.txt" 2>/dev/null || :
        jq -r '.Total | if .sampleCount > 0 then (.errorCount * 100 / .sampleCount) else 0 end' \
            "$rep/statistics.json" 2>/dev/null || :
        return 0
    fi

    if ! head -1 "$jtl" | grep -q '^timeStamp'; then
        # XML 形式など。GUI で開くことはできるが、ここでの一次集計は行わない
        printf 'XML 形式のため一次集計は省略 (GUI のリスナーで参照する)\n' > "$out/summary-stats.txt"
        return 0
    fi

    awk '
        function csvsplit(line, arr,   i, n, ch, fld, inq) {
            n = 0; fld = ""; inq = 0
            for (i = 1; i <= length(line); i++) {
                ch = substr(line, i, 1)
                if (inq) {
                    if (ch == "\"") {
                        if (substr(line, i + 1, 1) == "\"") { fld = fld "\""; i++ }
                        else inq = 0
                    } else fld = fld ch
                } else {
                    if (ch == "\"") inq = 1
                    else if (ch == ",") { arr[++n] = fld; fld = "" }
                    else fld = fld ch
                }
            }
            arr[++n] = fld
            return n
        }
        NR == 1 {
            n = csvsplit($0, h)
            for (i = 1; i <= n; i++) col[h[i]] = i
            next
        }
        {
            n = csvsplit($0, f)
            total++
            if (f[col["success"]] != "true") ng++
            e = f[col["elapsed"]] + 0
            sum += e
            if (max == "" || e > max) max = e
            t = f[col["timeStamp"]] + 0
            if (first == "" || t < first) first = t
            if (last == "" || t > last) last = t
        }
        END {
            if (total == 0) { print "サンプルが 0 件"; print "__RATE__ 0"; exit }
            dur = (last - first) / 1000.0
            printf "サンプル数   : %d\n", total
            printf "エラー       : %d (%.2f%%)\n", ng, ng * 100.0 / total
            printf "平均応答     : %.1f ms\n", sum / total
            printf "最大応答     : %d ms\n", max
            if (dur > 0) printf "スループット : %.2f req/s\n", total / dur
            printf "__RATE__ %.4f\n", ng * 100.0 / total
        }
    ' "$jtl" > "$out/.stats-raw"

    grep -v '^__RATE__' "$out/.stats-raw" > "$out/summary-stats.txt"
    awk '/^__RATE__/ { print $2 }' "$out/.stats-raw"
    rm -f "$out/.stats-raw"
}

# =============================================================================
# サブコマンド
# =============================================================================
cmd_list() {
    printf 'テスト計画 (%s):\n' "$JMETER_PLANS_DIR"
    found=0
    for f in "$JMETER_PLANS_DIR"/*.jmx; do
        [ -f "$f" ] || continue
        found=1
        printf '  %-40s %s\n' "$(basename "$f")" "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
    done
    [ "$found" -eq 1 ] || printf '  (なし) — GUI で作った .jmx を compose/jmeter/test-plans/ へ置く\n'
}

cmd_targets() {
    printf '対象サービス (%s) — 既定: %s\n\n' "$JMETER_TARGETS_FILE" "$(default_target)"
    printf '%-12s %-8s %-14s %-6s %-24s %s\n' NAME PROTO HOST PORT PATH NOTE
    targets_json | jq -r '.targets | to_entries[] |
        [.key, .value.protocol, .value.host, (.value.port|tostring), .value.path, (.value.note // "")] | @tsv' |
    while IFS="$(printf '\t')" read -r n proto host port path note; do
        printf '%-12s %-8s %-14s %-6s %-24s %s\n' "$n" "$proto" "$host" "$port" "$path" "$note"
    done
}

cmd_version() {
    jmeter --version
    printf '\nJava:\n'
    java -version 2>&1
}

cmd_doctor() {
    rc=0
    printf '=== jmeter-run doctor ===\n'

    printf '%s: ' 'JMeter 本体'
    v="$(jmeter --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    if [ -n "$v" ]; then printf 'OK (%s)\n' "$v"; else printf 'NG\n'; rc=1; fi

    printf '%s: ' 'テスト計画ディレクトリ'
    if [ -d "$JMETER_PLANS_DIR" ]; then
        printf 'OK (%s に .jmx が %s 件)\n' "$JMETER_PLANS_DIR" \
            "$(find "$JMETER_PLANS_DIR" -maxdepth 1 -name '*.jmx' -type f | wc -l)"
    else
        printf 'NG (%s が無い)\n' "$JMETER_PLANS_DIR"; rc=1
    fi

    printf '%s: ' '結果ディレクトリ (書き込み)'
    if touch "$JMETER_RESULTS_DIR/.write-test" 2>/dev/null; then
        rm -f "$JMETER_RESULTS_DIR/.write-test"
        printf 'OK (%s)\n' "$JMETER_RESULTS_DIR"
    else
        printf 'NG (%s へ書けない)\n' "$JMETER_RESULTS_DIR"; rc=1
    fi

    printf '%s: ' 'user.properties'
    if [ -f "$JMETER_USER_PROPERTIES" ]; then
        printf 'OK (%s)\n' "$JMETER_USER_PROPERTIES"
    else
        printf 'NG (%s が無い)\n' "$JMETER_USER_PROPERTIES"; rc=1
    fi

    printf '%s: ' 'targets.json'
    if targets_json | jq -e '.targets' >/dev/null 2>&1; then
        printf 'OK (%s 件)\n' "$(target_names | wc -l)"
    else
        printf 'NG (JSON が壊れている)\n'; rc=1
    fi

    printf '%s: ' '追加 jar (lib-ext)'
    if [ -d "$JMETER_LIB_EXT" ]; then
        printf 'OK (%s 件)\n' "$(find "$JMETER_LIB_EXT" -name '*.jar' | wc -l)"
    else
        printf '— (未マウント)\n'
    fi

    printf '%s: ' '自己証明書 (トラストストア)'
    if [ -d "$JMETER_TRUST_DIR" ] && [ -n "$(find "$JMETER_TRUST_DIR" -name '*.crt' 2>/dev/null | head -1)" ]; then
        printf 'OK (.crt %s 件)\n' "$(find "$JMETER_TRUST_DIR" -name '*.crt' | wc -l)"
    else
        printf '— (HTTPS 対象を使わないなら不要)\n'
    fi

    printf '\n--- 対象への到達確認 ---\n'
    for n in $(target_names); do
        url="$(target_field "$n" protocol)://$(target_field "$n" host):$(target_field "$n" port)$(target_field "$n" path)"
        printf '%-12s %-48s' "$n" "$url"
        if curl -sk -o /dev/null --connect-timeout 3 --max-time 6 "$url" 2>/dev/null; then
            printf '到達 OK\n'
        else
            printf '到達不可 (未起動なら想定内)\n'
        fi
    done

    printf '\n--- JVM ---\n'
    printf 'HEAP=%s\n' "${JMETER_HEAP:-(JMeter 既定: -Xms1g -Xmx1g)}"

    return $rc
}

cmd_report() {
    src="${1:-}"
    [ -n "$src" ] || die "結果ディレクトリ名か .jtl を指定する (例: report 20260919-120000_sample-frontend_frontend)"
    case "$src" in
        /*) : ;;
        *) src="$JMETER_RESULTS_DIR/$src" ;;
    esac
    if [ -d "$src" ]; then
        jtl="$src/result.jtl"
        out="$src/report"
    else
        jtl="$src"
        out="$(dirname "$jtl")/report"
    fi
    [ -f "$jtl" ] || die "jtl が見つからない: $jtl"
    rm -rf "$out"
    log "HTML レポートを再生成: $jtl -> $out"
    jmeter -q "$JMETER_USER_PROPERTIES" -g "$jtl" -o "$out"
    log "完了: $out/index.html"
}

cmd_clean() {
    mode="${1:---days}"
    arg="${2:-7}"
    case "$mode" in
        --all)
            log "結果をすべて削除: $JMETER_RESULTS_DIR"
            find "$JMETER_RESULTS_DIR" -mindepth 1 -maxdepth 1 \
                ! -name 'README.md' ! -name '.gitkeep' -exec rm -rf {} +
            ;;
        --days)
            log "$arg 日より古い結果を削除: $JMETER_RESULTS_DIR"
            find "$JMETER_RESULTS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$arg" -exec rm -rf {} +
            ;;
        *) die "clean の引数は --days N か --all" ;;
    esac
    log "残りの結果:"
    ls -1 "$JMETER_RESULTS_DIR" 2>/dev/null | sed 's/^/  /' || true
}

cmd_exec() {
    exec jmeter "$@"
}

# -----------------------------------------------------------------------------
# run — 本体
# -----------------------------------------------------------------------------
cmd_run() {
    plan_arg=""
    target_arg=""
    extra=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --target|-T) target_arg="${2:-}"; shift 2 ;;
            --name|-N) JMETER_RUN_NAME="${2:-}"; shift 2 ;;
            --) shift; extra="$*"; break ;;
            -*) die "不明なオプション: $1 (jmeter へ直接渡す引数は -- の後ろに書く)" ;;
            *)
                [ -z "$plan_arg" ] || die "テスト計画は 1 つだけ指定する"
                plan_arg="$1"; shift ;;
        esac
    done

    plan="$(resolve_plan "$plan_arg")"
    target="$(resolve_target "${target_arg:-$JMETER_TARGET}")"

    proto="$(target_field "$target" protocol)"
    host="$(target_field "$target" host)"
    port="$(target_field "$target" port)"
    path="$(target_field "$target" path)"

    plan_name="$(basename "$plan" .jmx)"
    stamp="$(date '+%Y%m%d-%H%M%S')"
    run_id="${JMETER_RUN_NAME:-${stamp}_${plan_name}_${target}}"
    out_dir="$JMETER_RESULTS_DIR/$run_id"
    mkdir -p "$out_dir"

    jtl="$out_dir/result.jtl"
    jlog="$out_dir/jmeter.log"
    report_dir="$out_dir/report"

    # --- 結果の保存形式 -----------------------------------------------------
    # csv … 既定。1 行 1 サンプルで小さく速い。GUI のリスナーからも HTML
    #        レポートからも読める (性能試験の通常運用はこちら)
    # xml … 応答本文やヘッダまで保存できる。GUI の「結果をツリーで表示」で
    #        中身まで追える代わりに肥大化し、HTML レポートは生成できない
    fmt="$JMETER_RESULTS_FORMAT"
    case "$fmt" in
        csv|xml) : ;;
        *) die "JMETER_RESULTS_FORMAT は csv か xml (指定値: $fmt)" ;;
    esac

    gen_report="$JMETER_GENERATE_REPORT"
    if [ "$fmt" = "xml" ] && [ "$gen_report" = "true" ]; then
        log "注意: XML 形式では HTML ダッシュボードを生成できないため無効化する (生成は CSV のときだけ)"
        gen_report=false
    fi

    # --- JVM ヒープ ----------------------------------------------------------
    # JMeter 同梱の起動スクリプトは HEAP をそのまま JVM へ渡す。
    # スレッド数 (= 仮想ユーザ数) を増やすときはここも一緒に上げる。
    if [ -n "$JMETER_HEAP" ]; then
        HEAP="$JMETER_HEAP"
        export HEAP
    fi

    # --- 自己証明書 ----------------------------------------------------------
    ts="$(build_truststore)" || ts=""
    if [ -n "$ts" ]; then
        JVM_ARGS="${JVM_ARGS:-} -Djavax.net.ssl.trustStore=$ts -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=changeit"
        export JVM_ARGS
    fi

    precheck "$proto://$host:$port$path"

    # --- JMeter へ渡すプロパティ --------------------------------------------
    # テスト計画側は ${__P(名前,既定値)} で受ける。GUI で開いたときは既定値で
    # 動くので、同じ .jmx を GUI と CLI の両方でそのまま使える。
    set -- \
        -Jtarget.protocol="$proto" \
        -Jtarget.host="$host" \
        -Jtarget.port="$port" \
        -Jtarget.path="$path" \
        -Jjmeter.save.saveservice.output_format="$fmt" \
        -Jjmeter.save.saveservice.response_data="$JMETER_SAVE_RESPONSE_DATA" \
        -Jsearch_paths="$JMETER_LIB_EXT" \
        -Juser.classpath="$JMETER_LIB_EXT"

    # 負荷条件の環境変数 (compose の environment: で渡す)。
    # 空のものは渡さず、テスト計画側の既定値を活かす
    for spec in \
        "threads:JMETER_THREADS" \
        "rampup:JMETER_RAMPUP" \
        "duration:JMETER_DURATION" \
        "loops:JMETER_LOOPS" \
        "startup.delay:JMETER_STARTUP_DELAY" \
        "think.time.base:JMETER_THINK_TIME_BASE" \
        "think.time.range:JMETER_THINK_TIME_RANGE" \
        "connect.timeout:JMETER_CONNECT_TIMEOUT" \
        "response.timeout:JMETER_RESPONSE_TIMEOUT" \
        "throughput.per.min:JMETER_THROUGHPUT_PER_MIN"
    do
        key="${spec%%:*}"
        var="${spec##*:}"
        eval "val=\${$var:-}"
        [ -z "$val" ] || set -- "$@" "-J$key=$val"
    done

    # 任意の追加プロパティ (JMETER_PROPS="key=value key2=value2")
    for kv in $JMETER_PROPS; do
        set -- "$@" "-J$kv"
    done

    # --- 実行条件の記録 ------------------------------------------------------
    # 「この結果がどの条件で出たか」を結果ディレクトリ内で完結させる。
    # これが無いと、後から別の結果と比較するときに再現できない。
    cp "$plan" "$out_dir/plan.jmx"
    {
        printf '# JMeter 実行条件 (自動生成)\n'
        printf 'run_id            : %s\n' "$run_id"
        printf 'started_at        : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'test_plan         : %s\n' "$(basename "$plan")"
        printf 'target            : %s (%s://%s:%s%s)\n' "$target" "$proto" "$host" "$port" "$path"
        printf 'results_format    : %s\n' "$fmt"
        printf 'html_report       : %s\n' "$gen_report"
        printf 'heap              : %s\n' "${HEAP:-JMeter 既定 (-Xms1g -Xmx1g)}"
        printf 'jmeter_version    : %s\n' "$(jmeter --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
        printf 'java_version      : %s\n' "$(java -version 2>&1 | head -1)"
        printf 'properties        :\n'
        for p in "$@"; do printf '  %s\n' "$p"; done
    } > "$out_dir/run-info.txt"

    log "========================================================================"
    log " テスト計画 : $(basename "$plan")"
    log " 対象       : $target ($proto://$host:$port$path)"
    log " 出力先     : compose/jmeter/results/$run_id/"
    log "========================================================================"

    set +e
    if [ "$gen_report" = "true" ]; then
        jmeter -n -t "$plan" -l "$jtl" -j "$jlog" \
            -q "$JMETER_USER_PROPERTIES" \
            -e -o "$report_dir" \
            "$@" $extra 2>&1 | tee "$out_dir/summary.log"
        rc=$?
    else
        jmeter -n -t "$plan" -l "$jtl" -j "$jlog" \
            -q "$JMETER_USER_PROPERTIES" \
            "$@" $extra 2>&1 | tee "$out_dir/summary.log"
        rc=$?
    fi
    set -e

    # --- 一次集計 ------------------------------------------------------------
    # HTML レポートを開く前に、合否の当たりを標準出力へ出す。
    # 値の出どころは HTML レポートと同じ statistics.json にそろえる
    # (レポートが無いときだけ jtl を直接読む)。
    if [ -f "$jtl" ]; then
        rate="$(compute_stats "$jtl" "$report_dir" "$out_dir")"

        if [ -s "$out_dir/summary-stats.txt" ]; then
            printf '\n'
            sed 's/^/[jmeter-run] /' "$out_dir/summary-stats.txt" >&2
        fi

        if [ -n "$JMETER_MAX_ERROR_RATE" ] && [ -n "$rate" ]; then
            if awk -v r="$rate" -v m="$JMETER_MAX_ERROR_RATE" 'BEGIN { exit !(r > m) }'; then
                log "判定: エラー率 ${rate}% が上限 ${JMETER_MAX_ERROR_RATE}% を超えた"
                rc=2
            else
                log "判定: エラー率 ${rate}% (上限 ${JMETER_MAX_ERROR_RATE}%) — 合格"
            fi
        fi
    fi

    # 最新結果への目印 (Windows の bind mount ではシンボリックリンクを作れない
    # ことがあるため、必ず作れるテキストも併せて置く)
    printf '%s\n' "$run_id" > "$JMETER_RESULTS_DIR/LATEST.txt"
    ln -sfn "$run_id" "$JMETER_RESULTS_DIR/latest" 2>/dev/null || true

    log "------------------------------------------------------------------------"
    log " 結果 (ホスト側): compose/jmeter/results/$run_id/"
    log "   result.jtl        JMeter GUI のリスナーから開く (参照するファイル名に指定)"
    log "   report/index.html HTML ダッシュボード (ブラウザで開く)"
    log "   jmeter.log        JMeter 自身のログ (エラーの一次調査)"
    log "   run-info.txt      この実行の条件 (再現用)"
    log "   plan.jmx          実行したテスト計画のコピー"
    log "------------------------------------------------------------------------"
    return $rc
}

# =============================================================================
# 入口
# =============================================================================
sub="${1:-run}"
[ $# -eq 0 ] || shift

case "$sub" in
    run) cmd_run "$@" ;;
    list) cmd_list "$@" ;;
    targets) cmd_targets "$@" ;;
    doctor) cmd_doctor "$@" ;;
    report) cmd_report "$@" ;;
    clean) cmd_clean "$@" ;;
    version) cmd_version "$@" ;;
    exec) cmd_exec "$@" ;;
    help|-h|--help) usage ;;
    # サブコマンド名でなければ .jmx の指定とみなす (run の省略形)
    *.jmx) cmd_run "$sub" "$@" ;;
    *) printf 'ERROR: 不明なサブコマンド: %s\n\n' "$sub" >&2; usage >&2; exit 1 ;;
esac
