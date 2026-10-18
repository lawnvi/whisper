package com.vireen.whisper.agent;

import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Wire format between the desktop and whisper-agent. Pure Java (no Android
 * APIs) so it is tested on the host JVM.
 *
 * <p>Every connection to the agent's socket starts with a hello:
 * {@code "WAG1"}, u8 role, u32 stream number (big-endian), 32-byte token.
 * Control connections then exchange length-prefixed UTF-8 JSON messages
 * (u32 big-endian length, payload). A stream's video and audio connections
 * carry the scrcpy media format (codec id, then 12-byte packet headers; video
 * starts with one status byte), and its input connection carries scrcpy
 * control messages, so the desktop reuses its scrcpy parsers.
 *
 * <p>The phone's own Whisper reaches the agent over loopback TCP instead
 * (see {@link AppLink}), where any app could connect, so it never sends the
 * token: its hello is {@code "WAG2"}, u8 role, u32 stream, 32-byte client
 * nonce; the agent answers with its own nonce and a MAC proving it knows the
 * token, and the client then proves it too ({@link #agentProof},
 * {@link #clientProof}). Only then does the connection carry the same bytes
 * as an adb one.
 */
public final class Wire {
    public static final byte[] MAGIC = {'W', 'A', 'G', '1'};
    public static final byte[] MAGIC_APP = {'W', 'A', 'G', '2'};
    public static final int TOKEN_BYTES = 32;
    public static final int NONCE_BYTES = 32;
    public static final int MAC_BYTES = 32;
    public static final int HELLO_BYTES = 4 + 1 + 4 + TOKEN_BYTES;
    public static final int APP_HELLO_BYTES = 4 + 1 + 4 + NONCE_BYTES;
    public static final int MAX_MESSAGE_BYTES = 4 * 1024 * 1024;

    public static final int ROLE_CONTROL = 1;
    public static final int ROLE_VIDEO = 2;
    public static final int ROLE_AUDIO = 3;
    public static final int ROLE_INPUT = 4;

    /**
     * Set in the role byte of the inner connection the app link opens for
     * the phone's Whisper: its sessions own the agent ({@link AgentServer}).
     */
    public static final int ROLE_FLAG_APP = 0x80;

    /**
     * Agent protocol version; desktops refuse agents they do not know.
     * 2: persistent agent, app link, {@code status}, per-session streams.
     */
    public static final int PROTOCOL_VERSION = 2;

    private static final byte[] AGENT_LABEL = "whisper-agent link agent".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CLIENT_LABEL = "whisper-agent link client".getBytes(StandardCharsets.US_ASCII);

    private Wire() {
    }

    public static final class Hello {
        public final int role;
        public final int stream;

        /** Opened by the app link for the phone's Whisper. */
        public final boolean app;

        Hello(int role, int stream, boolean app) {
            this.role = role;
            this.stream = stream;
            this.app = app;
        }
    }

    /** An app-link hello: role, stream and the client's nonce, as sent. */
    public static final class AppHello {
        public final int role;
        public final int stream;
        public final byte[] raw;

        AppHello(int role, int stream, byte[] raw) {
            this.role = role;
            this.stream = stream;
            this.raw = raw;
        }
    }

    /** Reads and checks a hello; returns null when it is malformed or the token is wrong. */
    public static Hello readHello(InputStream input, byte[] expectedToken) throws IOException {
        byte[] hello = new byte[HELLO_BYTES];
        new DataInputStream(input).readFully(hello);
        for (int i = 0; i < MAGIC.length; i++) {
            if (hello[i] != MAGIC[i]) {
                return null;
            }
        }
        boolean app = (hello[4] & ROLE_FLAG_APP) != 0;
        int role = hello[4] & 0x7f;
        int stream = readInt(hello, 5);
        byte[] token = new byte[TOKEN_BYTES];
        System.arraycopy(hello, 9, token, 0, TOKEN_BYTES);
        if (!constantTimeEquals(token, expectedToken)) {
            return null;
        }
        if (role < ROLE_CONTROL || role > ROLE_INPUT) {
            return null;
        }
        return new Hello(role, stream, app);
    }

    /** Reads an app-link hello; null when its magic or role is wrong. */
    public static AppHello readAppHello(InputStream input) throws IOException {
        byte[] hello = new byte[APP_HELLO_BYTES];
        new DataInputStream(input).readFully(hello);
        for (int i = 0; i < MAGIC_APP.length; i++) {
            if (hello[i] != MAGIC_APP[i]) {
                return null;
            }
        }
        int role = hello[4] & 0xff;
        if (role < ROLE_CONTROL || role > ROLE_INPUT) {
            return null;
        }
        return new AppHello(role, readInt(hello, 5), hello);
    }

    public static byte[] appHello(int role, int stream, byte[] clientNonce) {
        if (clientNonce.length != NONCE_BYTES) {
            throw new IllegalArgumentException("nonce must be " + NONCE_BYTES + " bytes");
        }
        byte[] out = new byte[APP_HELLO_BYTES];
        System.arraycopy(MAGIC_APP, 0, out, 0, 4);
        out[4] = (byte) role;
        writeInt(out, 5, stream);
        System.arraycopy(clientNonce, 0, out, 9, NONCE_BYTES);
        return out;
    }

    /** The agent's answer to [hello]: HMAC-SHA256(token, label, hello, agent nonce). */
    public static byte[] agentProof(byte[] token, byte[] hello, byte[] agentNonce) {
        return mac(token, AGENT_LABEL, hello, agentNonce);
    }

    /** The client's answer to the agent's nonce, with its own label. */
    public static byte[] clientProof(byte[] token, byte[] hello, byte[] agentNonce) {
        return mac(token, CLIENT_LABEL, hello, agentNonce);
    }

    private static byte[] mac(byte[] key, byte[]... parts) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            for (byte[] part : parts) {
                mac.update(part);
            }
            return mac.doFinal();
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    private static int readInt(byte[] bytes, int offset) {
        return ((bytes[offset] & 0xff) << 24) | ((bytes[offset + 1] & 0xff) << 16) | ((bytes[offset + 2] & 0xff) << 8)
                | (bytes[offset + 3] & 0xff);
    }

    private static void writeInt(byte[] bytes, int offset, int value) {
        bytes[offset] = (byte) (value >>> 24);
        bytes[offset + 1] = (byte) (value >>> 16);
        bytes[offset + 2] = (byte) (value >>> 8);
        bytes[offset + 3] = (byte) value;
    }

    public static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            out.append(Character.forDigit((b >> 4) & 0xf, 16)).append(Character.forDigit(b & 0xf, 16));
        }
        return out.toString();
    }

    public static byte[] hello(int role, int stream, byte[] token) {
        byte[] out = new byte[HELLO_BYTES];
        System.arraycopy(MAGIC, 0, out, 0, 4);
        out[4] = (byte) role;
        writeInt(out, 5, stream);
        System.arraycopy(token, 0, out, 9, TOKEN_BYTES);
        return out;
    }

    public static boolean constantTimeEquals(byte[] a, byte[] b) {
        if (a == null || b == null || a.length != b.length) {
            return false;
        }
        int diff = 0;
        for (int i = 0; i < a.length; i++) {
            diff |= a[i] ^ b[i];
        }
        return diff == 0;
    }

    public static byte[] parseHex(String hex) {
        if (hex == null || hex.length() % 2 != 0) {
            return null;
        }
        byte[] out = new byte[hex.length() / 2];
        for (int i = 0; i < out.length; i++) {
            int high = Character.digit(hex.charAt(2 * i), 16);
            int low = Character.digit(hex.charAt(2 * i + 1), 16);
            if (high < 0 || low < 0) {
                return null;
            }
            out[i] = (byte) ((high << 4) | low);
        }
        return out;
    }

    /** Reads one length-prefixed message; null at a clean end of stream. */
    public static String readMessage(InputStream input) throws IOException {
        DataInputStream data = new DataInputStream(input);
        int length;
        try {
            length = data.readInt();
        } catch (EOFException e) {
            return null;
        }
        if (length < 0 || length > MAX_MESSAGE_BYTES) {
            throw new IOException("message too large: " + length);
        }
        byte[] payload = new byte[length];
        data.readFully(payload);
        return new String(payload, StandardCharsets.UTF_8);
    }

    public static void writeMessage(OutputStream output, String message) throws IOException {
        byte[] payload = message.getBytes(StandardCharsets.UTF_8);
        if (payload.length > MAX_MESSAGE_BYTES) {
            throw new IOException("message too large: " + payload.length);
        }
        byte[] frame = new byte[4 + payload.length];
        frame[0] = (byte) (payload.length >>> 24);
        frame[1] = (byte) (payload.length >>> 16);
        frame[2] = (byte) (payload.length >>> 8);
        frame[3] = (byte) payload.length;
        System.arraycopy(payload, 0, frame, 4, payload.length);
        output.write(frame);
        output.flush();
    }
}
