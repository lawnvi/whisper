package com.vireen.whisper.agent;

import com.genymobile.scrcpy.util.Ln;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;

import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;

/**
 * The phone's own Whisper reaches the agent here. Apps may not connect to
 * the shell user's abstract sockets (SELinux has no {@code connectto} from
 * untrusted apps to shell), but they may use loopback TCP, where every other
 * app can connect too. So a connection only gets through when
 * <ul>
 *   <li>its owner, as {@code /proc/net/tcp} reports it, is Whisper's uid,
 *   when the table can be read at all, and</li>
 *   <li>it proves knowledge of the link token without sending it, after
 *   the agent proved the same ({@link Wire#agentProof}), so a process that
 *   squats the port after the agent died learns nothing either.</li>
 * </ul>
 * The token reaches Whisper only through its own provider, which only the
 * shell user and root may call ({@link PhoneApp#link}). An accepted
 * connection becomes a plain byte pipe into the agent's abstract socket,
 * with an inner hello that marks it as the app's, so everything behind it
 * is the code adb connections already use.
 */
final class AppLink {

    private static final int HANDSHAKE_TIMEOUT_MS = 2_000;
    private static final int BUFFER_BYTES = 64 * 1024;

    private final AgentServer server;
    private final String socketName;
    private final byte[] innerToken;
    private final byte[] appToken = new byte[Wire.TOKEN_BYTES];
    private final SecureRandom random = new SecureRandom();
    private ServerSocket listener;
    private int failures;

    AppLink(AgentServer server, String socketName, byte[] innerToken) {
        this.server = server;
        this.socketName = socketName;
        this.innerToken = innerToken.clone();
        random.nextBytes(appToken);
    }

    byte[] token() {
        return appToken.clone();
    }

    int port() {
        return listener.getLocalPort();
    }

    void start() throws IOException {
        listener = new ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"));
        Thread accept = new Thread(() -> {
            while (true) {
                try {
                    Socket socket = listener.accept();
                    new Thread(() -> handle(socket), "agent-link").start();
                } catch (IOException e) {
                    Ln.e("app link accept failed", e);
                    return;
                }
                if (failures > 8) {
                    // Someone keeps guessing; slow them down.
                    android.os.SystemClock.sleep(500);
                }
            }
        }, "agent-link-accept");
        accept.setDaemon(true);
        accept.start();
    }

    private void handle(Socket socket) {
        LocalSocket inner = null;
        try {
            socket.setTcpNoDelay(true);
            socket.setSoTimeout(HANDSHAKE_TIMEOUT_MS);
            int expected = server.whisperUid();
            int owner = ownerOf(socket);
            if (expected < 0 || (owner >= 0 && owner != expected)) {
                Ln.w("app link refused uid " + owner);
                refuse(socket);
                return;
            }
            InputStream in = socket.getInputStream();
            OutputStream out = socket.getOutputStream();
            Wire.AppHello hello = Wire.readAppHello(in);
            if (hello == null) {
                refuse(socket);
                return;
            }
            byte[] nonce = new byte[Wire.NONCE_BYTES];
            random.nextBytes(nonce);
            byte[] answer = new byte[Wire.NONCE_BYTES + Wire.MAC_BYTES];
            System.arraycopy(nonce, 0, answer, 0, Wire.NONCE_BYTES);
            System.arraycopy(Wire.agentProof(appToken, hello.raw, nonce), 0, answer, Wire.NONCE_BYTES, Wire.MAC_BYTES);
            out.write(answer);
            out.flush();
            byte[] proof = new byte[Wire.MAC_BYTES];
            new DataInputStream(in).readFully(proof);
            if (!Wire.constantTimeEquals(proof, Wire.clientProof(appToken, hello.raw, nonce))) {
                refuse(socket);
                return;
            }
            failures = 0;
            socket.setSoTimeout(0);
            inner = new LocalSocket();
            inner.connect(new LocalSocketAddress(socketName));
            inner.getOutputStream().write(Wire.hello(hello.role | Wire.ROLE_FLAG_APP, hello.stream, innerToken));
            pipe(socket, inner);
        } catch (IOException e) {
            close(socket);
            if (inner != null) {
                AgentServer.closeQuietly(inner);
            }
        }
    }

    private void refuse(Socket socket) {
        failures++;
        close(socket);
    }

    /** Copies both ways until either side ends, then closes both. */
    private static void pipe(Socket outer, LocalSocket inner) throws IOException {
        InputStream fromOuter = outer.getInputStream();
        OutputStream toOuter = outer.getOutputStream();
        InputStream fromInner = inner.getInputStream();
        OutputStream toInner = inner.getOutputStream();
        Runnable end = () -> {
            close(outer);
            AgentServer.closeQuietly(inner);
        };
        Thread up = new Thread(() -> {
            copy(fromOuter, toInner);
            end.run();
        }, "agent-link-up");
        up.setDaemon(true);
        up.start();
        copy(fromInner, toOuter);
        end.run();
    }

    private static void copy(InputStream in, OutputStream out) {
        byte[] buffer = new byte[BUFFER_BYTES];
        try {
            int read;
            while ((read = in.read(buffer)) > 0) {
                out.write(buffer, 0, read);
                out.flush();
            }
        } catch (IOException e) {
            // One side went away.
        }
    }

    /** The uid that owns the connecting socket, or -1 if unknown. */
    private static int ownerOf(Socket socket) {
        int client = socket.getPort();
        int ours = socket.getLocalPort();
        for (String path : new String[]{"/proc/net/tcp6", "/proc/net/tcp"}) {
            int uid = ProcNetParser.uidOf(read(path), client, ours);
            if (uid >= 0) {
                return uid;
            }
        }
        return -1;
    }

    private static String read(String path) {
        try (FileInputStream in = new FileInputStream(path)) {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[16 * 1024];
            int read;
            while ((read = in.read(buffer)) > 0) {
                out.write(buffer, 0, read);
            }
            return new String(out.toByteArray(), StandardCharsets.US_ASCII);
        } catch (IOException e) {
            return null;
        }
    }

    private static void close(Socket socket) {
        try {
            socket.close();
        } catch (IOException e) {
            // ignore
        }
    }
}
