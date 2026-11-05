package com.vireen.whisper

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * Finds the port this phone's own adbd announces for Wireless debugging. The
 * system picks a new one each time, and an app can read it only from mDNS. Other
 * phones on the Wi-Fi announce the same services, so only this device's count.
 */
internal class AdbPortFinder(context: Context, private val serviceType: String) {
    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private val waiting = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null
    private var onChange: ((Int?) -> Unit)? = null
    private val found = mutableMapOf<String, Int>()

    /** Calls [changed] on the main thread with the port, or null when it goes. */
    fun start(changed: (Int?) -> Unit) {
        main.post {
            if (listener != null) {
                return@post
            }
            onChange = changed
            val discovery = object : NsdManager.DiscoveryListener {
                override fun onServiceFound(info: NsdServiceInfo) {
                    main.post { enqueue(info) }
                }

                override fun onServiceLost(info: NsdServiceInfo) {
                    main.post {
                        if (found.remove(info.serviceName) != null) {
                            onChange?.invoke(found.values.firstOrNull())
                        }
                    }
                }

                override fun onDiscoveryStarted(serviceType: String) = Unit
                override fun onDiscoveryStopped(serviceType: String) = Unit
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            }
            listener = discovery
            nsd.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, discovery)
        }
    }

    fun stop() {
        main.post {
            val discovery = listener ?: return@post
            listener = null
            onChange = null
            waiting.clear()
            found.clear()
            try {
                nsd.stopServiceDiscovery(discovery)
            } catch (_: IllegalArgumentException) {
                // Already stopped.
            }
        }
    }

    private fun enqueue(info: NsdServiceInfo) {
        if (listener == null) {
            return
        }
        waiting.addLast(info)
        resolveNext()
    }

    // NsdManager resolves one service at a time on older systems.
    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving) {
            return
        }
        val next = waiting.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(
            next,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    main.post {
                        resolving = false
                        resolveNext()
                    }
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    val port = info.port
                    val mine = isThisDevice(info.host)
                    main.post {
                        resolving = false
                        if (mine && listener != null) {
                            found[info.serviceName] = port
                            onChange?.invoke(port)
                        }
                        resolveNext()
                    }
                }
            },
        )
    }

    private fun isThisDevice(host: InetAddress?): Boolean {
        if (host == null) {
            return false
        }
        if (host.isLoopbackAddress) {
            return true
        }
        return try {
            NetworkInterface.getNetworkInterfaces().asSequence()
                .flatMap { it.inetAddresses.asSequence() }
                .any { it == host }
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        const val PAIRING = "_adb-tls-pairing._tcp"
        const val CONNECT = "_adb-tls-connect._tcp"
    }
}
