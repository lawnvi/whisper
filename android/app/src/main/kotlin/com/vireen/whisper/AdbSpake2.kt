package com.vireen.whisper

import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * SPAKE2 over Ed25519 as adb pairing runs it: wire-compatible with BoringSSL's
 * SPAKE2_generate_msg / SPAKE2_process_msg, its "password scalar hack" included.
 * Client role only (adbd is the server).
 *
 * Plain BigInteger arithmetic, not constant time: it runs once per pairing, on
 * the phone itself, over a one-time code, and the APK stays free of a crypto
 * library for this.
 */
internal class AdbSpake2(password: ByteArray, random: SecureRandom = SecureRandom()) {
    private val passwordHash = sha512(password)
    private val privateScalar: BigInteger
    private val passwordScalar: BigInteger

    /** Our message for the server: P + w·M. */
    val message: ByteArray

    init {
        val seed = ByteArray(64).also(random::nextBytes)
        // Eight times a reduced scalar: clears the cofactor on the peer's point.
        privateScalar = littleEndian(seed).mod(ORDER).shiftLeft(3)
        passwordScalar = maskScalar(littleEndian(passwordHash).mod(ORDER))
        message = BASE.times(privateScalar).plus(M.times(passwordScalar)).encode()
    }

    /** The 64-byte shared key; throws when the server's message is not a point. */
    fun process(theirMessage: ByteArray): ByteArray {
        require(theirMessage.size == MESSAGE_BYTES) { "bad message size" }
        val masked = Point.decode(theirMessage)
        val shared = masked.plus(N.times(passwordScalar).negate()).times(privateScalar)
        val digest = MessageDigest.getInstance("SHA-512")
        digest.updatePrefixed(CLIENT_NAME)
        digest.updatePrefixed(SERVER_NAME)
        digest.updatePrefixed(message)
        digest.updatePrefixed(theirMessage)
        digest.updatePrefixed(shared.encode())
        digest.updatePrefixed(passwordHash)
        return digest.digest()
    }

    private fun MessageDigest.updatePrefixed(data: ByteArray) {
        val length = ByteArray(8)
        for (i in 0 until 8) {
            length[i] = (data.size.toLong() ushr (8 * i)).toByte()
        }
        update(length)
        update(data)
    }

    /** A point of Ed25519 in extended coordinates; addition covers the whole curve. */
    private class Point(val x: BigInteger, val y: BigInteger, val z: BigInteger, val t: BigInteger) {
        fun plus(other: Point): Point {
            val a = (y - x) * (other.y - other.x) % P
            val b = (y + x) * (other.y + other.x) % P
            val c = t * D2 % P * other.t % P
            val d = z * BigInteger.TWO % P * other.z % P
            val e = b - a
            val f = d - c
            val g = d + c
            val h = b + a
            return Point(e * f % P, g * h % P, f * g % P, e * h % P)
        }

        fun negate() = Point(P - x, y, z, P - t)

        fun times(scalar: BigInteger): Point {
            var result = IDENTITY
            for (bit in scalar.bitLength() - 1 downTo 0) {
                result = result.plus(result)
                if (scalar.testBit(bit)) {
                    result = result.plus(this)
                }
            }
            return result
        }

        fun encode(): ByteArray {
            val inverse = z.modInverse(P)
            val affineX = (x * inverse).mod(P)
            val affineY = (y * inverse).mod(P)
            val out = toLittleEndian(affineY)
            if (affineX.testBit(0)) {
                out[31] = (out[31].toInt() or 0x80).toByte()
            }
            return out
        }

        companion object {
            val IDENTITY = Point(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)

            fun decode(bytes: ByteArray): Point {
                val sign = bytes[31].toInt() and 0x80 != 0
                val copy = bytes.copyOf()
                copy[31] = (copy[31].toInt() and 0x7f).toByte()
                val y = littleEndian(copy)
                require(y < P) { "not a point" }
                val yy = y * y % P
                val numerator = (yy - BigInteger.ONE).mod(P)
                val denominator = (CURVE_D * yy + BigInteger.ONE).mod(P)
                val xx = numerator * denominator.modInverse(P) % P
                var x = xx.modPow(P.add(BigInteger.valueOf(3)).shiftRight(3), P)
                if ((x * x - xx).mod(P).signum() != 0) {
                    x = x * SQRT_MINUS_ONE % P
                }
                require((x * x - xx).mod(P).signum() == 0) { "not a point" }
                if (x.testBit(0) != sign) {
                    x = P - x
                }
                require(x.signum() != 0 || !sign) { "not a point" }
                return Point(x.mod(P), y, BigInteger.ONE, x * y % P)
            }
        }
    }

    private companion object {
        const val MESSAGE_BYTES = 32

        // adb hashes the names with their trailing NUL.
        val CLIENT_NAME = "adb pair client\u0000".toByteArray(Charsets.US_ASCII)
        val SERVER_NAME = "adb pair server\u0000".toByteArray(Charsets.US_ASCII)

        val P: BigInteger = BigInteger.ONE.shiftLeft(255) - BigInteger.valueOf(19)
        val ORDER: BigInteger = BigInteger.ONE.shiftLeft(252) +
            BigInteger("27742317777372353535851937790883648493")
        val CURVE_D: BigInteger = (P - BigInteger.valueOf(121665)) *
            BigInteger.valueOf(121666).modInverse(P) % P
        val D2: BigInteger = CURVE_D * BigInteger.TWO % P
        val SQRT_MINUS_ONE: BigInteger =
            BigInteger.TWO.modPow(P.subtract(BigInteger.ONE).shiftRight(2), P)

        val BASE: Point = run {
            // y = 4/5, x positive (even).
            val y = BigInteger.valueOf(4) * BigInteger.valueOf(5).modInverse(P) % P
            Point.decode(toLittleEndian(y))
        }

        // BoringSSL's fixed points (spake25519.cc). They may carry a small-order
        // part; every scalar they meet is a multiple of eight, which clears it.
        val M: Point = Point.decode(hex("5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e"))
        val N: Point = Point.decode(hex("10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778"))

        /**
         * BoringSSL leaves the password scalar unshifted and instead adds
         * multiples of the group order until it is a multiple of eight.
         */
        fun maskScalar(reduced: BigInteger): BigInteger {
            var scalar = reduced
            var multiple = ORDER
            for (bit in 0..2) {
                if (scalar.testBit(bit)) {
                    scalar += multiple
                }
                multiple = multiple.shiftLeft(1)
            }
            return scalar
        }

        fun sha512(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-512").digest(data)

        fun littleEndian(bytes: ByteArray) = BigInteger(1, bytes.reversedArray())

        fun toLittleEndian(value: BigInteger): ByteArray {
            val big = value.toByteArray()
            val out = ByteArray(32)
            for (i in 0 until minOf(32, big.size)) {
                out[i] = big[big.size - 1 - i]
            }
            return out
        }

        fun hex(text: String) = ByteArray(text.length / 2) {
            text.substring(2 * it, 2 * it + 2).toInt(16).toByte()
        }
    }
}
