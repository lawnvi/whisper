package com.vireen.whisper.agent;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Runs shell commands as the agent's own user (shell). */
final class Shell {
    private Shell() {
    }

    static String run(String command) {
        try {
            Process process = new ProcessBuilder("sh", "-c", command).redirectErrorStream(true).start();
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (InputStream in = process.getInputStream()) {
                byte[] buffer = new byte[8192];
                int r;
                while ((r = in.read(buffer)) > 0) {
                    out.write(buffer, 0, r);
                }
            }
            process.waitFor();
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "Exception: " + e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return "Exception: interrupted";
        }
    }
}
