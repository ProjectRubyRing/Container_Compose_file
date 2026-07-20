package com.example.async;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.time.OffsetDateTime;

/**
 * async-receiver — 非同期処理チェーンの終端。
 *
 * <p>経路: app-front/app-back → SQS(ElasticMQ) → lambda-esm(poller) → Lambda(handler.py)
 *          → ALB(nginx) → <b>このサーブレット</b>。</p>
 *
 * <p>URL: コンテキストルート {@code /async} (jboss-web.xml) + マッピング {@code /receive}
 *          = <b>/async/receive</b>。ALB のリスナールール {@code /async/*} がここへ転送する。</p>
 *
 * <p>受信した POST ボディを標準出力 (docker logs app-back) と、書き込み可能なら
 *    /mnt/logs/app-back-async.log (偽装 EFS → cwagent が拾う) に記録し、200 を返す。</p>
 */
@WebServlet(name = "AsyncReceiverServlet", urlPatterns = {"/receive"})
public class AsyncReceiverServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        // --- リクエストボディを読み取る ---
        StringBuilder sb = new StringBuilder();
        try (BufferedReader reader = req.getReader()) {
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append('\n');
            }
        }
        String body = sb.toString().stripTrailing();
        String messageId = req.getHeader("X-SQS-Message-Id");
        String source = req.getHeader("X-Source");
        String forwardedFor = req.getHeader("X-Forwarded-For");
        String timestamp = OffsetDateTime.now().toString();

        String logLine = String.format(
                "%s [app-back][async-receiver] source=%s messageId=%s xff=%s bytes=%d body=%s",
                timestamp, source, messageId, forwardedFor,
                body.getBytes(StandardCharsets.UTF_8).length,
                body.replace('\n', ' '));

        // CloudWatch Logs 相当 (docker logs app-back で確認)
        System.out.println(logLine);

        // 偽装 EFS に追記 (書けない環境ではスキップ)。cwagent がこのファイルも拾える。
        writeToEfsLog(logLine);

        // --- 200 OK (JSON) を返す ---
        resp.setStatus(HttpServletResponse.SC_OK);
        resp.setContentType("application/json; charset=UTF-8");
        try (PrintWriter out = resp.getWriter()) {
            out.printf(
                "{\"status\":\"received\",\"messageId\":%s,\"receivedAt\":\"%s\",\"echoBytes\":%d}%n",
                messageId == null ? "null" : "\"" + messageId + "\"",
                timestamp,
                body.getBytes(StandardCharsets.UTF_8).length);
        }
    }

    /** 動作確認用。GET /async/receive で生存確認できる。 */
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        resp.setStatus(HttpServletResponse.SC_OK);
        resp.setContentType("text/plain; charset=UTF-8");
        resp.getWriter().println("async-receiver alive (POST here to receive SQS→Lambda→ALB payloads)");
    }

    private void writeToEfsLog(String logLine) {
        String dir = System.getenv().getOrDefault("EFS_LOG_DIR", "/mnt/logs");
        try {
            Path path = Paths.get(dir, "app-back-async.log");
            if (Files.isDirectory(path.getParent())) {
                Files.writeString(path, logLine + System.lineSeparator(),
                        StandardCharsets.UTF_8,
                        StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            }
        } catch (Exception ignore) {
            // 偽装 EFS 未マウント等は無視 (標準出力には既に記録済み)
        }
    }
}
