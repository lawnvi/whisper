package com.vireen.whisper.agent;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;

/** Host-side tests for {@link Wire}; run by script/build_window_agent.sh. */
public final class WireTest {

    private static int passed;

    public static void main(String... args) throws Exception {
        helloRoundTrip();
        helloRejectsWrongTokenAndMagic();
        helloRejectsUnknownRole();
        messagesRoundTrip();
        messageRejectsOversizedLength();
        parseHex();
        appHelloRoundTrip();
        appProofsFixture();
        appFlagOnInnerHello();
        System.out.println("WireTest: " + passed + " passed");
    }

    private static byte[] token(int seed) {
        byte[] token = new byte[Wire.TOKEN_BYTES];
        for (int i = 0; i < token.length; i++) {
            token[i] = (byte) (seed + i * 7);
        }
        return token;
    }

    private static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
        passed++;
    }

    private static void helloRoundTrip() throws IOException {
        byte[] hello = Wire.hello(Wire.ROLE_VIDEO, 0x01020304, token(3));
        check(hello.length == Wire.HELLO_BYTES, "hello length");
        Wire.Hello parsed = Wire.readHello(new ByteArrayInputStream(hello), token(3));
        check(parsed != null, "hello accepted");
        check(parsed.role == Wire.ROLE_VIDEO, "role kept");
        check(parsed.stream == 0x01020304, "stream kept, big-endian");
        // Shared fixture with the Dart side: role 4, stream 7, token 0..31.
        byte[] fixed = new byte[Wire.TOKEN_BYTES];
        for (int i = 0; i < fixed.length; i++) {
            fixed[i] = (byte) i;
        }
        byte[] fixture = Wire.hello(Wire.ROLE_INPUT, 7, fixed);
        check(hex(fixture).equals("5741473104000000070001020304050607"
                + "08090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"), "hello fixture");
    }

    private static void helloRejectsWrongTokenAndMagic() throws IOException {
        byte[] hello = Wire.hello(Wire.ROLE_CONTROL, 0, token(3));
        check(Wire.readHello(new ByteArrayInputStream(hello), token(4)) == null, "wrong token refused");
        hello[0] = 'X';
        check(Wire.readHello(new ByteArrayInputStream(hello), token(3)) == null, "wrong magic refused");
        try {
            Wire.readHello(new ByteArrayInputStream(new byte[5]), token(3));
            check(false, "short hello must throw");
        } catch (IOException expected) {
            check(true, "short hello throws");
        }
    }

    private static void helloRejectsUnknownRole() throws IOException {
        byte[] hello = Wire.hello(9, 0, token(1));
        check(Wire.readHello(new ByteArrayInputStream(hello), token(1)) == null, "unknown role refused");
        hello = Wire.hello(0, 0, token(1));
        check(Wire.readHello(new ByteArrayInputStream(hello), token(1)) == null, "role 0 refused");
    }

    private static void messagesRoundTrip() throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        Wire.writeMessage(out, "{\"id\":1}");
        Wire.writeMessage(out, "你好");
        byte[] bytes = out.toByteArray();
        check(bytes[3] == 8, "length prefix is big-endian byte count");
        ByteArrayInputStream in = new ByteArrayInputStream(bytes);
        check("{\"id\":1}".equals(Wire.readMessage(in)), "first message");
        check("你好".equals(Wire.readMessage(in)), "utf-8 message");
        check(Wire.readMessage(in) == null, "clean end");
    }

    private static void messageRejectsOversizedLength() {
        byte[] frame = {0x7f, 0, 0, 0};
        try {
            Wire.readMessage(new ByteArrayInputStream(frame));
            check(false, "oversized length must throw");
        } catch (IOException expected) {
            check(true, "oversized length throws");
        }
    }

    private static void parseHex() {
        check(Wire.parseHex("00ff10") != null && Wire.parseHex("00ff10")[1] == (byte) 0xff, "hex parsed");
        check(Wire.parseHex("abc") == null, "odd length refused");
        check(Wire.parseHex("zz") == null, "bad digit refused");
        check(Wire.parseHex(null) == null, "null refused");
    }

    private static void appHelloRoundTrip() throws IOException {
        byte[] nonce = token(9);
        byte[] hello = Wire.appHello(Wire.ROLE_VIDEO, 5, nonce);
        check(hello.length == Wire.APP_HELLO_BYTES, "app hello length");
        Wire.AppHello parsed = Wire.readAppHello(new ByteArrayInputStream(hello));
        check(parsed != null && parsed.role == Wire.ROLE_VIDEO && parsed.stream == 5, "app hello parsed");
        check(java.util.Arrays.equals(parsed.raw, hello), "raw hello kept for the proofs");
        hello[3] = '1';
        check(Wire.readAppHello(new ByteArrayInputStream(hello)) == null, "WAG1 is not an app hello");
        check(Wire.readAppHello(new ByteArrayInputStream(Wire.appHello(7, 0, nonce))) == null, "bad role refused");
    }

    /** Shared fixture with the Dart side (agent_link_test.dart). */
    private static void appProofsFixture() {
        byte[] fixed = new byte[Wire.TOKEN_BYTES];
        byte[] nonce = new byte[Wire.NONCE_BYTES];
        byte[] agentNonce = new byte[Wire.NONCE_BYTES];
        for (int i = 0; i < fixed.length; i++) {
            fixed[i] = (byte) i;
            nonce[i] = (byte) (0x40 + i);
            agentNonce[i] = (byte) (0x80 + i);
        }
        byte[] hello = Wire.appHello(Wire.ROLE_CONTROL, 0, nonce);
        byte[] agent = Wire.agentProof(fixed, hello, agentNonce);
        byte[] client = Wire.clientProof(fixed, hello, agentNonce);
        check(agent.length == Wire.MAC_BYTES && client.length == Wire.MAC_BYTES, "proof length");
        check(!java.util.Arrays.equals(agent, client), "the two proofs differ");
        check(hex(agent).equals(AGENT_PROOF_FIXTURE), "agent proof fixture");
        check(hex(client).equals(CLIENT_PROOF_FIXTURE), "client proof fixture");
    }

    private static final String AGENT_PROOF_FIXTURE = "e4ddd461114ffa5e6f2d6257c4839d0ea45d0e60dca85e3797ab25467d9fb233";
    private static final String CLIENT_PROOF_FIXTURE = "3f90f97e9d0f9d308fa247989e6b6a5acad6277eeb63d3c9513d426912ec49d5";

    private static void appFlagOnInnerHello() throws IOException {
        byte[] hello = Wire.hello(Wire.ROLE_CONTROL | Wire.ROLE_FLAG_APP, 0, token(2));
        Wire.Hello parsed = Wire.readHello(new ByteArrayInputStream(hello), token(2));
        check(parsed != null && parsed.app && parsed.role == Wire.ROLE_CONTROL, "app flag read");
        parsed = Wire.readHello(new ByteArrayInputStream(Wire.hello(Wire.ROLE_INPUT, 0, token(2))), token(2));
        check(parsed != null && !parsed.app, "adb hello has no app flag");
    }

    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte b : bytes) {
            out.append(String.format("%02x", b & 0xff));
        }
        return out.toString();
    }
}
