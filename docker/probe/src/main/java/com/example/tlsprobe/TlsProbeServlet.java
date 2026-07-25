package com.example.tlsprobe;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import javax.net.ssl.SSLSession;
import java.io.IOException;
import java.io.PrintWriter;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Optional;

/**
 * tls-probe — front/back の JVM 自身から HTTPS の REST API を呼び出して、
 * JVM トラストストアによるサーバ証明書の検証が成功することを確認する検証用サーブレット。
 *
 * <p>app-front / app-back の <b>両方</b>に同じ WAR を配備しているため、
 * どちらのコンテナからでも同じ URL で確認できる:</p>
 *
 * <pre>
 *   GET /tls-probe/check                      → 既定ターゲット (secure-api へ直接 HTTPS)
 *   GET /tls-probe/check?target=direct        → https://secure-api:8443/api/v1/ping
 *   GET /tls-probe/check?target=alb           → https://alb/secure/v1/ping (ALB 経由)
 *   GET /tls-probe/check?url=https://.../x    → 任意 URL
 *   GET /tls-probe/check?target=alb&amp;method=POST&amp;body={...}
 *   GET /tls-probe/truststore                 → 使用中トラストストアの内容サマリ
 * </pre>
 *
 * <p>HTTP クライアントは JDK 標準の {@link java.net.http.HttpClient} を使う。
 * 既定の {@code SSLContext} を使うため、検証に使われるトラストストアは
 * システムプロパティ {@code javax.net.ssl.trustStore} (entrypoint.sh が
 * keytool で CA を取り込んだコピーを指定する) がそのまま効く。
 * つまり「アプリコードは無改変のまま、トラストストアの設定だけで HTTPS が通る」
 * ことを確認できる。</p>
 *
 * <p>検証失敗時 (PKIX path building failed 等) は HTTP 502 と、原因の例外チェーンを
 * JSON で返す。ここが 200 になるか 502 になるかで、トラストストアへの
 * インポートが効いているかどうかを機械的に判定できる。</p>
 */
@WebServlet(name = "TlsProbeServlet", urlPatterns = {"/check", "/truststore"})
public class TlsProbeServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;

    /** secure-api へ直接 HTTPS 呼び出しする際の既定 URL */
    private static final String DEFAULT_DIRECT_URL =
            envOrDefault("SECURE_API_URL", "https://secure-api:8443/api/v1/ping");

    /** ALB (HTTPS リスナー) 経由で secure-api を呼び出す際の既定 URL */
    private static final String DEFAULT_ALB_URL =
            envOrDefault("SECURE_API_VIA_ALB_URL", "https://alb/secure/v1/ping");

    private static final int MAX_BODY_CHARS = 2000;

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        if (req.getServletPath().endsWith("/truststore")) {
            writeTrustStoreInfo(resp);
        } else {
            writeCheck(req, resp);
        }
    }

    /** POST でも同じ検証ができるようにしておく (body を渡したい場合など)。 */
    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        doGet(req, resp);
    }

    // ------------------------------------------------------------------------
    // GET /tls-probe/check
    // ------------------------------------------------------------------------
    private void writeCheck(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String target = req.getParameter("target");
        String url = req.getParameter("url");
        if (url == null || url.isBlank()) {
            url = "alb".equalsIgnoreCase(target) ? DEFAULT_ALB_URL : DEFAULT_DIRECT_URL;
            if (target == null || target.isBlank()) {
                target = "direct";
            }
        } else {
            target = "custom";
        }

        String method = req.getParameter("method");
        method = (method == null || method.isBlank()) ? "GET" : method.toUpperCase();
        String body = req.getParameter("body");

        StringBuilder json = new StringBuilder();
        json.append("{\n");
        json.append("  \"role\": ").append(quote(roleName())).append(",\n");
        json.append("  \"target\": ").append(quote(target)).append(",\n");
        json.append("  \"url\": ").append(quote(url)).append(",\n");
        json.append("  \"method\": ").append(quote(method)).append(",\n");
        json.append("  \"trustStore\": ").append(quote(trustStorePath())).append(",\n");

        long started = System.nanoTime();
        try {
            HttpClient client = HttpClient.newBuilder()
                    // 既定の SSLContext = JVM トラストストア (javax.net.ssl.trustStore) を使う。
                    // ここで独自 TrustManager を差し込んでいない = 検証を迂回していない。
                    .connectTimeout(Duration.ofSeconds(5))
                    .followRedirects(HttpClient.Redirect.NORMAL)
                    .build();

            HttpRequest.BodyPublisher publisher = (body == null || body.isBlank())
                    ? HttpRequest.BodyPublishers.noBody()
                    : HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8);

            HttpRequest.Builder rb = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(10))
                    .header("Accept", "application/json")
                    .header("X-Probe-Source", roleName());
            if (body != null && !body.isBlank()) {
                rb.header("Content-Type", "application/json");
            }
            rb.method(method, publisher);

            HttpResponse<String> response = client.send(rb.build(), HttpResponse.BodyHandlers.ofString());
            long elapsedMs = (System.nanoTime() - started) / 1_000_000L;

            boolean ok = response.statusCode() >= 200 && response.statusCode() < 400;
            json.append("  \"ok\": ").append(ok).append(",\n");
            json.append("  \"httpStatus\": ").append(response.statusCode()).append(",\n");
            json.append("  \"elapsedMs\": ").append(elapsedMs).append(",\n");
            appendTlsSection(json, response.sslSession());
            json.append("  \"responseBody\": ").append(quote(truncate(response.body()))).append("\n");
            json.append("}\n");

            resp.setStatus(ok ? HttpServletResponse.SC_OK : HttpServletResponse.SC_BAD_GATEWAY);
        } catch (Exception e) {
            long elapsedMs = (System.nanoTime() - started) / 1_000_000L;
            json.append("  \"ok\": false,\n");
            json.append("  \"elapsedMs\": ").append(elapsedMs).append(",\n");
            json.append("  \"error\": {\n");
            json.append("    \"type\": ").append(quote(e.getClass().getName())).append(",\n");
            json.append("    \"message\": ").append(quote(String.valueOf(e.getMessage()))).append(",\n");
            json.append("    \"causes\": [");
            List<String> causes = new ArrayList<>();
            Throwable c = e.getCause();
            int guard = 0;
            while (c != null && guard++ < 10) {
                causes.add(c.getClass().getName() + ": " + c.getMessage());
                c = c.getCause();
            }
            for (int i = 0; i < causes.size(); i++) {
                json.append(i == 0 ? "\n      " : ",\n      ").append(quote(causes.get(i)));
            }
            json.append(causes.isEmpty() ? "]," : "\n    ],").append("\n");
            // 典型的な失敗の意味を添える (トラストストア未設定なのか、名前不一致なのか)
            json.append("    \"hint\": ").append(quote(hintFor(e))).append("\n");
            json.append("  }\n");
            json.append("}\n");

            resp.setStatus(HttpServletResponse.SC_BAD_GATEWAY);
            log("[tls-probe] check failed url=" + url + " : " + e);
        }

        writeJson(resp, json.toString());
    }

    /** TLS セッション情報 (プロトコル / 暗号スイート / 相手証明書) を JSON に追記する。 */
    private void appendTlsSection(StringBuilder json, Optional<SSLSession> maybeSession) {
        if (maybeSession.isEmpty()) {
            json.append("  \"tls\": null,\n");
            return;
        }
        SSLSession s = maybeSession.get();
        json.append("  \"tls\": {\n");
        json.append("    \"protocol\": ").append(quote(s.getProtocol())).append(",\n");
        json.append("    \"cipherSuite\": ").append(quote(s.getCipherSuite())).append(",\n");
        try {
            Certificate[] chain = s.getPeerCertificates();
            json.append("    \"peerChainLength\": ").append(chain.length).append(",\n");
            if (chain.length > 0 && chain[0] instanceof X509Certificate leaf) {
                json.append("    \"peerSubject\": ").append(quote(leaf.getSubjectX500Principal().getName())).append(",\n");
                json.append("    \"peerIssuer\": ").append(quote(leaf.getIssuerX500Principal().getName())).append(",\n");
                json.append("    \"peerNotAfter\": ").append(quote(String.valueOf(leaf.getNotAfter()))).append(",\n");
                json.append("    \"peerSans\": ").append(quote(sansOf(leaf))).append(",\n");
            }
            // チェーンの最後 (サーバが提示した最上位) が何かを見ると、
            // 自己署名 1 枚なのか 中間 CA つきなのかが判別できる
            if (chain.length > 0 && chain[chain.length - 1] instanceof X509Certificate top) {
                json.append("    \"topOfPresentedChain\": ").append(quote(top.getSubjectX500Principal().getName())).append("\n");
            } else {
                json.append("    \"topOfPresentedChain\": null\n");
            }
        } catch (Exception e) {
            json.append("    \"peerCertificateError\": ").append(quote(String.valueOf(e))).append("\n");
        }
        json.append("  },\n");
    }

    // ------------------------------------------------------------------------
    // GET /tls-probe/truststore
    // ------------------------------------------------------------------------
    private void writeTrustStoreInfo(HttpServletResponse resp) throws IOException {
        String path = trustStorePath();
        String password = System.getProperty("javax.net.ssl.trustStorePassword", "changeit");

        StringBuilder json = new StringBuilder();
        json.append("{\n");
        json.append("  \"role\": ").append(quote(roleName())).append(",\n");
        json.append("  \"trustStore\": ").append(quote(path)).append(",\n");
        json.append("  \"trustStoreTypeProperty\": ")
            .append(quote(System.getProperty("javax.net.ssl.trustStoreType", "(unset: 自動判別)"))).append(",\n");

        try {
            Path p = Paths.get(path);
            if (!Files.isReadable(p)) {
                json.append("  \"readable\": false,\n");
                json.append("  \"note\": ").append(quote(
                        "トラストストアを読めません。entrypoint.sh の取り込みが動いていない可能性があります"))
                    .append("\n}\n");
                resp.setStatus(HttpServletResponse.SC_INTERNAL_SERVER_ERROR);
                writeJson(resp, json.toString());
                return;
            }
            KeyStore ks = KeyStore.getInstance(p.toFile(), password.toCharArray());
            List<String> localAliases = new ArrayList<>();
            int total = 0;
            for (String alias : Collections.list(ks.aliases())) {
                total++;
                // entrypoint が取り込んだ検証用の証明書だけを抜き出して表示する
                if (alias.contains("local-test") || alias.contains("alb-") || alias.contains("selfsigned")) {
                    Certificate cert = ks.getCertificate(alias);
                    String subject = (cert instanceof X509Certificate x)
                            ? x.getSubjectX500Principal().getName() : "(non-x509)";
                    localAliases.add(alias + " => " + subject);
                }
            }
            json.append("  \"readable\": true,\n");
            json.append("  \"totalEntries\": ").append(total).append(",\n");
            json.append("  \"importedForThisTest\": [");
            for (int i = 0; i < localAliases.size(); i++) {
                json.append(i == 0 ? "\n    " : ",\n    ").append(quote(localAliases.get(i)));
            }
            json.append(localAliases.isEmpty() ? "]\n" : "\n  ]\n");
            json.append("}\n");
            resp.setStatus(HttpServletResponse.SC_OK);
        } catch (Exception e) {
            json.append("  \"readable\": false,\n");
            json.append("  \"error\": ").append(quote(e.getClass().getName() + ": " + e.getMessage())).append("\n");
            json.append("}\n");
            resp.setStatus(HttpServletResponse.SC_INTERNAL_SERVER_ERROR);
        }

        writeJson(resp, json.toString());
    }

    // ------------------------------------------------------------------------
    // ヘルパー
    // ------------------------------------------------------------------------

    /** 実際に使われるトラストストアのパス (未指定なら JDK 既定の cacerts)。 */
    private static String trustStorePath() {
        String p = System.getProperty("javax.net.ssl.trustStore");
        if (p != null && !p.isBlank()) {
            return p;
        }
        return System.getProperty("java.home", "") + "/lib/security/cacerts (JDK 既定)";
    }

    private static String roleName() {
        String name = System.getenv("OTEL_SERVICE_NAME");
        return (name == null || name.isBlank()) ? "unknown" : name;
    }

    private static String envOrDefault(String key, String fallback) {
        String v = System.getenv(key);
        return (v == null || v.isBlank()) ? fallback : v;
    }

    /** 失敗理由の当たりをつけるための短い説明。 */
    private static String hintFor(Exception e) {
        String all = flatten(e);
        if (all.contains("PKIX path building failed") || all.contains("unable to find valid certification path")) {
            return "サーバ証明書を検証できません。CA (または自己署名証明書) が JVM トラストストアに"
                 + " 取り込まれていない可能性があります (/tls-probe/truststore で確認)";
        }
        if (all.contains("No subject alternative names") || all.contains("doesn't match")
                || all.contains("No name matching")) {
            return "証明書は信頼できましたがホスト名が SAN と一致しません。接続先ホスト名と"
                 + " 証明書の subjectAltName を合わせてください";
        }
        if (all.contains("certificate_expired") || all.contains("NotAfter")) {
            return "証明書の有効期限切れです。pki-init を PKI_FORCE_REGENERATE=1 で作り直してください";
        }
        if (all.contains("Connection refused") || all.contains("ConnectException")) {
            return "TCP 接続自体ができていません。相手コンテナの起動と、平文 HTTP で"
                 + " HTTPS ポートを叩いていないかを確認してください";
        }
        return "詳細は causes を参照してください";
    }

    private static String flatten(Throwable t) {
        StringBuilder sb = new StringBuilder();
        int guard = 0;
        while (t != null && guard++ < 10) {
            sb.append(t.getClass().getName()).append(": ").append(t.getMessage()).append(" | ");
            t = t.getCause();
        }
        return sb.toString();
    }

    private static String sansOf(X509Certificate cert) {
        try {
            var sans = cert.getSubjectAlternativeNames();
            if (sans == null) {
                return "(none)";
            }
            StringBuilder sb = new StringBuilder();
            for (List<?> entry : sans) {
                if (entry.size() >= 2) {
                    if (sb.length() > 0) {
                        sb.append(", ");
                    }
                    // type 2 = dNSName, 7 = iPAddress
                    sb.append(entry.get(0)).append(":").append(entry.get(1));
                }
            }
            return sb.toString();
        } catch (Exception e) {
            return "(unavailable: " + e.getClass().getSimpleName() + ")";
        }
    }

    private static String truncate(String s) {
        if (s == null) {
            return "";
        }
        return s.length() <= MAX_BODY_CHARS ? s : s.substring(0, MAX_BODY_CHARS) + "...(truncated)";
    }

    private static String quote(String s) {
        if (s == null) {
            return "null";
        }
        StringBuilder sb = new StringBuilder(s.length() + 16).append('"');
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            switch (ch) {
                case '"'  -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (ch < 0x20) {
                        sb.append(String.format("\\u%04x", (int) ch));
                    } else {
                        sb.append(ch);
                    }
                }
            }
        }
        return sb.append('"').toString();
    }

    private static void writeJson(HttpServletResponse resp, String json) throws IOException {
        resp.setContentType("application/json; charset=UTF-8");
        resp.setCharacterEncoding("UTF-8");
        try (PrintWriter out = resp.getWriter()) {
            out.print(json);
        }
    }
}
