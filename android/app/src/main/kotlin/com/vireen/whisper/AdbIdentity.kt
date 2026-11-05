package com.vireen.whisper

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.math.BigInteger
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.RSAPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager

/**
 * The key this phone's Whisper presents to its own adbd. Once paired it opens a
 * shell on this phone, so the private key is kept encrypted under a key in the
 * Android keystore, and only in this app's no-backup folder.
 */
internal class AdbIdentity private constructor(
    private val privateKey: PrivateKey,
    private val certificate: X509Certificate,
) {
    /** The public key in adb's own format, as pairing sends it. */
    val adbPublicKey: ByteArray
        get() {
            val encoded = Base64.encodeToString(rsaPublicKeyStruct(), Base64.NO_WRAP)
            return "$encoded whisper@android\u0000".toByteArray(Charsets.US_ASCII)
        }

    /**
     * TLS 1.3 with this key as the client certificate. adbd's certificate isn't
     * checked: pairing proves itself through the code, and adbd decides what our
     * key may do. Whisper's own trust in the agent comes through a provider only
     * the shell user can call, not through this connection.
     */
    fun tlsContext(): SSLContext {
        val context = SSLContext.getInstance("TLSv1.3")
        context.init(arrayOf(keyManager), arrayOf(TrustEverything), SecureRandom())
        return context
    }

    private val keyManager = object : X509ExtendedKeyManager() {
        override fun chooseClientAlias(
            keyType: Array<out String>?,
            issuers: Array<out Principal>?,
            socket: Socket?,
        ) = ALIAS

        override fun chooseEngineClientAlias(
            keyType: Array<out String>?,
            issuers: Array<out Principal>?,
            engine: SSLEngine?,
        ) = ALIAS

        override fun getCertificateChain(alias: String?) = arrayOf(certificate)
        override fun getPrivateKey(alias: String?) = privateKey
        override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(ALIAS)
        override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = null
        override fun chooseServerAlias(
            keyType: String?,
            issuers: Array<out Principal>?,
            socket: Socket?,
        ) = null
    }

    /** adb's RSAPublicKey struct: words, n0inv, modulus and R² little-endian, exponent. */
    private fun rsaPublicKeyStruct(): ByteArray {
        val key = certificate.publicKey as RSAPublicKey
        val words = KEY_BITS / 32
        val two32 = BigInteger.ONE.shiftLeft(32)
        val n0inv = two32 - key.modulus.mod(two32).modInverse(two32)
        val rr = BigInteger.ONE.shiftLeft(2 * KEY_BITS).mod(key.modulus)
        return ByteBuffer.allocate(4 + 4 + 2 * (KEY_BITS / 8) + 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(words)
            .putInt(n0inv.toInt())
            .put(littleEndian(key.modulus))
            .put(littleEndian(rr))
            .putInt(key.publicExponent.toInt())
            .array()
    }

    private fun littleEndian(value: BigInteger): ByteArray {
        val big = value.toByteArray()
        val out = ByteArray(KEY_BITS / 8)
        for (i in 0 until minOf(out.size, big.size)) {
            out[i] = big[big.size - 1 - i]
        }
        return out
    }

    private object TrustEverything : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun getAcceptedIssuers() = emptyArray<X509Certificate>()
    }

    companion object {
        private const val ALIAS = "whisper_adb_self"
        private const val KEY_BITS = 2048
        private const val GCM_NONCE = 12
        private const val GCM_TAG_BITS = 128

        /** This phone's identity, made the first time. */
        @Synchronized
        fun load(context: Context): AdbIdentity {
            val folder = File(context.noBackupFilesDir, "adb_self").apply { mkdirs() }
            val keyFile = File(folder, "key.enc")
            val certFile = File(folder, "cert.der")
            val factory = CertificateFactory.getInstance("X.509")
            if (keyFile.exists() && certFile.exists()) {
                try {
                    val pkcs8 = decrypt(keyFile.readBytes())
                    val key = KeyFactory.getInstance("RSA")
                        .generatePrivate(PKCS8EncodedKeySpec(pkcs8))
                    val cert = certFile.inputStream().use {
                        factory.generateCertificate(it) as X509Certificate
                    }
                    return AdbIdentity(key, cert)
                } catch (_: Exception) {
                    // The wrapping key is gone (a restore): pair again with a new one.
                }
            }
            val pair = KeyPairGenerator.getInstance("RSA")
                .apply { initialize(KEY_BITS) }
                .generateKeyPair()
            val der = selfSigned(pair.public.encoded, pair.private)
            val cert = der.inputStream().use {
                factory.generateCertificate(it) as X509Certificate
            }
            keyFile.writeBytes(encrypt(pair.private.encoded))
            certFile.writeBytes(der)
            return AdbIdentity(pair.private, cert)
        }

        private fun wrappingKey(): SecretKey {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            return generator.generateKey()
        }

        private fun encrypt(plain: ByteArray): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
            return cipher.iv + cipher.doFinal(plain)
        }

        private fun decrypt(data: ByteArray): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                wrappingKey(),
                GCMParameterSpec(GCM_TAG_BITS, data, 0, GCM_NONCE),
            )
            return cipher.doFinal(data, GCM_NONCE, data.size - GCM_NONCE)
        }

        /** A bare self-signed X.509 certificate: adbd only looks at its public key. */
        private fun selfSigned(publicKeyInfo: ByteArray, key: PrivateKey): ByteArray {
            val sha256WithRsa = der(
                0x30,
                der(0x06, byteArrayOf(0x2a, 0x86.toByte(), 0x48, 0x86.toByte(), 0xf7.toByte(), 0x0d, 1, 1, 0x0b)),
                der(0x05),
            )
            val name = der(
                0x30,
                der(
                    0x31,
                    der(
                        0x30,
                        der(0x06, byteArrayOf(0x55, 0x04, 0x03)),
                        der(0x0c, "whisper".toByteArray(Charsets.US_ASCII)),
                    ),
                ),
            )
            val validity = der(
                0x30,
                der(0x17, "250101000000Z".toByteArray(Charsets.US_ASCII)),
                der(0x17, "491231235959Z".toByteArray(Charsets.US_ASCII)),
            )
            val serial = BigInteger(64, SecureRandom()).add(BigInteger.ONE).toByteArray()
            val toBeSigned = der(
                0x30,
                der(0xa0, der(0x02, byteArrayOf(2))), // v3
                der(0x02, serial),
                sha256WithRsa,
                name,
                validity,
                name,
                publicKeyInfo,
            )
            val signature = Signature.getInstance("SHA256withRSA").run {
                initSign(key)
                update(toBeSigned)
                sign()
            }
            return der(0x30, toBeSigned, sha256WithRsa, der(0x03, byteArrayOf(0) + signature))
        }

        private fun der(tag: Int, vararg parts: ByteArray): ByteArray {
            val body = ByteArrayOutputStream().apply { parts.forEach(::write) }.toByteArray()
            val out = ByteArrayOutputStream()
            out.write(tag)
            when {
                body.size < 0x80 -> out.write(body.size)
                body.size < 0x100 -> {
                    out.write(0x81)
                    out.write(body.size)
                }
                else -> {
                    out.write(0x82)
                    out.write(body.size shr 8)
                    out.write(body.size and 0xff)
                }
            }
            out.write(body)
            return out.toByteArray()
        }
    }
}
