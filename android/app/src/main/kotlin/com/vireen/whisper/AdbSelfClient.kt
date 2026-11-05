package com.vireen.whisper

import android.net.ssl.SSLSockets
import android.os.Build
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.Closeable
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.SSLSocket

/** The code was wrong, or the system stopped offering pairing. */
internal class AdbPairingRefused : Exception()

/**
 * Pairing with this phone's own adbd, as `adb pair` does it (AOSP
 * adb/pairing_connection): TLS 1.3, SPAKE2 over the code plus a value exported
 * from that TLS session, then our public key for adbd's device id, both
 * encrypted with a key from SPAKE2.
 */
internal object AdbPairing {
    private const val PACKET_VERSION = 1
    private const val TYPE_SPAKE2 = 0
    private const val TYPE_PEER_INFO = 1
    private const val PEER_INFO_BYTES = 8192
    private const val GCM_TAG_BYTES = 16
    private const val MAX_PACKET = PEER_INFO_BYTES + GCM_TAG_BYTES
    private const val TIMEOUT_MS = 10_000

    // The NUL is part of the label on the wire.
    private const val EXPORT_LABEL = "adb-label\u0000"
    private const val EXPORT_BYTES = 64
    private const val KEY_INFO = "adb pairing_auth aes-128-gcm key"

    @RequiresApi(Build.VERSION_CODES.S)
    fun pair(identity: AdbIdentity, port: Int, code: String) {
        val plain = Socket()
        plain.connect(InetSocketAddress("127.0.0.1", port), TIMEOUT_MS)
        plain.soTimeout = TIMEOUT_MS
        plain.tcpNoDelay = true
        val tls = identity.tlsContext().socketFactory
            .createSocket(plain, "127.0.0.1", port, true) as SSLSocket
        tls.use { socket ->
            socket.useClientMode = true
            socket.startHandshake()
            val exported = SSLSockets.exportKeyingMaterial(socket, EXPORT_LABEL, null, EXPORT_BYTES)
                ?: throw AdbPairingRefused()
            val input = DataInputStream(socket.inputStream)
            val output = DataOutputStream(socket.outputStream)

            val spake2 = AdbSpake2(code.toByteArray(Charsets.US_ASCII) + exported)
            writePacket(output, TYPE_SPAKE2, spake2.message)
            val theirs = readPacket(input, TYPE_SPAKE2)
            val cipherKey = hkdf(spake2.process(theirs))

            val info = ByteArray(PEER_INFO_BYTES)
            val key = identity.adbPublicKey
            System.arraycopy(key, 0, info, 1, key.size) // first byte: type 0, an RSA key
            writePacket(output, TYPE_PEER_INFO, seal(cipherKey, info))
            // adbd drops the connection here if the code didn't match.
            val answer = try {
                readPacket(input, TYPE_PEER_INFO)
            } catch (_: Exception) {
                throw AdbPairingRefused()
            }
            open(cipherKey, answer)
        }
    }

    private fun writePacket(output: DataOutputStream, type: Int, payload: ByteArray) {
        output.writeByte(PACKET_VERSION)
        output.writeByte(type)
        output.writeInt(payload.size) // big-endian
        output.write(payload)
        output.flush()
    }

    private fun readPacket(input: DataInputStream, type: Int): ByteArray {
        val version = input.readUnsignedByte()
        val actual = input.readUnsignedByte()
        val size = input.readInt()
        if (version != PACKET_VERSION || actual != type || size <= 0 || size > MAX_PACKET) {
            throw AdbPairingRefused()
        }
        return ByteArray(size).also(input::readFully)
    }

    /** HKDF-SHA256 with no salt, 16 bytes out. */
    private fun hkdf(material: ByteArray): ByteArray {
        val extract = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
            doFinal(material)
        }
        val expand = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(extract, "HmacSHA256"))
            update(KEY_INFO.toByteArray(Charsets.US_ASCII))
            doFinal(byteArrayOf(1))
        }
        return expand.copyOf(16)
    }

    // Each direction counts its own messages; here that is one each, so nonce 0.
    private fun seal(key: ByteArray, plain: ByteArray): ByteArray =
        cipher(Cipher.ENCRYPT_MODE, key).doFinal(plain)

    private fun open(key: ByteArray, sealed: ByteArray): ByteArray = try {
        cipher(Cipher.DECRYPT_MODE, key).doFinal(sealed)
    } catch (_: Exception) {
        throw AdbPairingRefused()
    }

    private fun cipher(mode: Int, key: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BYTES * 8, ByteArray(12)))
        }
}

/**
 * A connection to this phone's own adbd over Wireless debugging: the adb wire
 * protocol after its TLS upgrade, enough to run a command and read its output.
 */
internal class AdbSelfShell private constructor(
    private val socket: Socket,
    private val input: DataInputStream,
    private val output: DataOutputStream,
) : Closeable {
    private var nextLocalId = 1

    /** Runs [command] with no terminal and returns what it printed. */
    fun run(command: String, timeoutMs: Int = SHELL_TIMEOUT_MS): String {
        socket.soTimeout = timeoutMs
        val localId = nextLocalId++
        write(output, A_OPEN, localId, 0, "shell,raw:$command\u0000".toByteArray(Charsets.UTF_8))
        val out = ByteArrayOutputStream()
        while (true) {
            val message = readFor(localId)
            when (message.command) {
                A_OKAY -> Unit
                A_WRTE -> {
                    out.write(message.data)
                    write(output, A_OKAY, localId, message.arg0, ByteArray(0))
                }
                A_CLSE -> {
                    write(output, A_CLSE, localId, message.arg0, ByteArray(0))
                    return out.toString(Charsets.UTF_8.name())
                }
                else -> throw IllegalStateException("unexpected adb message")
            }
        }
    }

    /** Writes [data] to [path], as `adb push` does, through adb's sync service. */
    fun push(data: ByteArray, path: String) {
        socket.soTimeout = SHELL_TIMEOUT_MS
        val localId = nextLocalId++
        write(output, A_OPEN, localId, 0, "sync:\u0000".toByteArray(Charsets.US_ASCII))
        val opened = readFor(localId)
        check(opened.command == A_OKAY) { "adbd refused the sync service" }
        val remoteId = opened.arg0

        send(localId, remoteId, syncPacket("SEND", "$path,$PUSH_MODE".toByteArray(Charsets.UTF_8)))
        var offset = 0
        while (offset < data.size) {
            val size = minOf(SYNC_CHUNK, data.size - offset)
            send(localId, remoteId, syncPacket("DATA", data.copyOfRange(offset, offset + size)))
            offset += size
        }
        // DONE carries the file's time where a length would be.
        val done = ByteBuffer.allocate(SYNC_HEADER).order(ByteOrder.LITTLE_ENDIAN)
            .put("DONE".toByteArray(Charsets.US_ASCII))
            .putInt((System.currentTimeMillis() / 1000).toInt())
            .array()
        send(localId, remoteId, done)

        var answer = readFor(localId)
        while (answer.command == A_OKAY) {
            answer = readFor(localId)
        }
        check(answer.command == A_WRTE && answer.data.size >= SYNC_HEADER) { "bad sync answer" }
        check(String(answer.data, 0, 4, Charsets.US_ASCII) == "OKAY") { "push refused" }
        write(output, A_OKAY, localId, remoteId, ByteArray(0))
        write(output, A_CLSE, localId, remoteId, ByteArray(0))
        // Its close, and any late acknowledgement.
        while (readFor(localId).command != A_CLSE) {
            continue
        }
    }

    /** One message, waiting for adbd's acknowledgement as the protocol asks. */
    private fun send(localId: Int, remoteId: Int, payload: ByteArray) {
        write(output, A_WRTE, localId, remoteId, payload)
        val ack = readFor(localId)
        check(ack.command == A_OKAY) { "adbd closed the sync service" }
    }

    private fun syncPacket(id: String, payload: ByteArray): ByteArray =
        ByteBuffer.allocate(SYNC_HEADER + payload.size).order(ByteOrder.LITTLE_ENDIAN)
            .put(id.toByteArray(Charsets.US_ASCII))
            .putInt(payload.size)
            .put(payload)
            .array()

    override fun close() {
        try {
            socket.close()
        } catch (_: Exception) {
            // Already gone.
        }
    }

    private class Message(val command: Int, val arg0: Int, val arg1: Int, val data: ByteArray)

    /**
     * The next message for stream [localId]. The last stream's closing messages
     * can still arrive after it has finished: they belong to no one now.
     */
    private fun readFor(localId: Int): Message {
        while (true) {
            val message = read(input)
            if (message.arg1 == localId) {
                return message
            }
        }
    }

    companion object {
        private const val A_CNXN = 0x4e584e43
        private const val A_OPEN = 0x4e45504f
        private const val A_OKAY = 0x59414b4f
        private const val A_CLSE = 0x45534c43
        private const val A_WRTE = 0x45545257
        private const val A_STLS = 0x534c5453
        private const val VERSION = 0x01000000
        private const val STLS_VERSION = 0x01000000
        private const val MAX_DATA = 1024 * 1024
        private const val HEADER_BYTES = 24
        private const val CONNECT_TIMEOUT_MS = 8_000
        private const val SHELL_TIMEOUT_MS = 20_000
        private const val SYNC_HEADER = 8
        private const val SYNC_CHUNK = 64 * 1024
        private const val PUSH_MODE = 420 // 0644

        /** Connects with a paired [identity]; throws when adbd won't have it. */
        fun connect(identity: AdbIdentity, port: Int): AdbSelfShell {
            val plain = Socket()
            try {
                plain.connect(InetSocketAddress("127.0.0.1", port), CONNECT_TIMEOUT_MS)
                plain.soTimeout = CONNECT_TIMEOUT_MS
                plain.tcpNoDelay = true
                val plainOut = DataOutputStream(plain.getOutputStream())
                write(plainOut, A_CNXN, VERSION, MAX_DATA, "host::\u0000".toByteArray(Charsets.US_ASCII))
                val first = read(DataInputStream(plain.getInputStream()))
                check(first.command == A_STLS) { "adbd asked for no TLS" }
                write(plainOut, A_STLS, STLS_VERSION, 0, ByteArray(0))
                val tls = identity.tlsContext().socketFactory
                    .createSocket(plain, "127.0.0.1", port, true) as SSLSocket
                tls.useClientMode = true
                tls.startHandshake()
                val input = DataInputStream(tls.inputStream)
                val output = DataOutputStream(tls.outputStream)
                // A key adbd doesn't know fails here, after the handshake.
                val hello = read(input)
                check(hello.command == A_CNXN) { "adbd refused the connection" }
                return AdbSelfShell(tls, input, output)
            } catch (error: Exception) {
                try {
                    plain.close()
                } catch (_: Exception) {
                    // Nothing more to do.
                }
                throw error
            }
        }

        private fun write(output: DataOutputStream, command: Int, arg0: Int, arg1: Int, data: ByteArray) {
            var sum = 0
            data.forEach { sum += it.toInt() and 0xff }
            val header = ByteBuffer.allocate(HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(command)
                .putInt(arg0)
                .putInt(arg1)
                .putInt(data.size)
                .putInt(sum)
                .putInt(command.inv())
                .array()
            output.write(header)
            output.write(data)
            output.flush()
        }

        private fun read(input: DataInputStream): Message {
            val header = ByteArray(HEADER_BYTES).also(input::readFully)
            val fields = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val command = fields.getInt(0)
            val arg0 = fields.getInt(4)
            val arg1 = fields.getInt(8)
            val length = fields.getInt(12)
            check(length in 0..MAX_DATA) { "bad adb message" }
            val data = ByteArray(length).also(input::readFully)
            return Message(command, arg0, arg1, data)
        }
    }
}
