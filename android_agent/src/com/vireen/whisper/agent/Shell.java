package com.vireen.whisper.agent;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Runs shell commands as the agent's own user (shell). */
final class Shell {
    private Shell() {
    }

    /** A command line through {@code sh -c}: fixed text and numbers only. */
    static String run(String command) {
        return exec("sh", "-c", command);
    }

    /**
     * A program and its arguments, with no shell in between, for anything
     * named by someone else (an app's activity, a request's app id): such a
     * name stays one argument whatever characters it holds.
     */
    static String exec(String... argv) {
        try {
            Process process = new ProcessBuilder(argv).redirectErrorStream(true).start();
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
