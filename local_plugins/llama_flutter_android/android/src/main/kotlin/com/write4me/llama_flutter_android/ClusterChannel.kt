package com.write4me.llama_flutter_android

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import kotlin.coroutines.resume

/**
 * Method channel for the phone cluster: run this phone as a worker, find
 * workers on the local network, and choose which ones the next model load
 * uses. Kept apart from the Pigeon-generated LlamaHostApi.
 */
class ClusterChannel(
    private val context: Context,
    messenger: BinaryMessenger,
    private val scope: CoroutineScope,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "llama_flutter_android/cluster")

    /** Set by the plugin while the app has an activity. */
    var activity: Activity? = null

    companion object {
        private const val TAG = "ClusterChannel"
    }

    /**
     * The worker runs in its own process, which Android (Samsung especially)
     * treats as background work and moves to slow cores once it's busy:
     * measured on an S24, its "moderate" cpuset has 4 of 8 cores, even with
     * battery Unrestricted. Binding it with BIND_IMPORTANT gives it this app's
     * priority, so while PrivateLM is on screen the worker gets all cores.
     * No BIND_AUTO_CREATE: this never starts the worker, it only attaches
     * whenever the worker runs.
     */
    private val workerPriority = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {}
        override fun onServiceDisconnected(name: ComponentName?) {}
    }

    private var multicastLock: WifiManager.MulticastLock? = null

    init {
        channel.setMethodCallHandler(this)
        acquireMulticastLock()
        context.bindService(
            Intent(context, ClusterWorkerService::class.java),
            workerPriority,
            Context.BIND_IMPORTANT
        )
    }

    /**
     * Android Wi-Fi hardware filters drop incoming UDP broadcast/multicast
     * packets (such as PrivateLM Mesh discovery beacons on port 50053) unless
     * a MulticastLock is held.
     */
    private fun acquireMulticastLock() {
        runCatching {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifi != null && multicastLock == null) {
                multicastLock = wifi.createMulticastLock("PrivateLM:MeshDiscovery").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        }.onFailure {
            Log.w(TAG, "Could not acquire MulticastLock", it)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startWorker" -> {
                val intent = Intent(context, ClusterWorkerService::class.java)
                    .putExtra(ClusterWorkerService.EXTRA_PORT,
                        call.argument<Int>("port") ?: ClusterWorkerService.DEFAULT_PORT)
                    .putExtra(ClusterWorkerService.EXTRA_THREADS, call.argument<Int>("threads") ?: 0)
                ContextCompat.startForegroundService(context, intent)
                result.success(null)
            }
            "stopWorker" -> {
                if (isWorkerRunning()) {
                    context.startService(Intent(context, ClusterWorkerService::class.java)
                        .setAction(ClusterWorkerService.ACTION_STOP))
                }
                result.success(null)
            }
            "workerStatus" -> {
                val status = ClusterWorkerService.readStatus(context)
                val alive = isWorkerRunning()
                // A process that died without saying so (killed) is stopped.
                val state = status.optString("state", "stopped")
                    .let { if (!alive && it != "error") "stopped" else it }
                result.success(mapOf(
                    "state" to state,
                    "error" to status.optString("error").takeIf { it.isNotEmpty() },
                    "peer" to status.optString("peer").takeIf { alive && it.isNotEmpty() },
                    "heldMb" to status.optLong("heldMb"),
                    "ramMb" to status.optLong("ramMb"),
                    "bandwidth" to status.optDouble("bandwidth", 0.0),
                    "throttled" to (alive && status.optBoolean("throttled")),
                    "id" to ClusterWorkerService.workerId(context),
                    "batteryUnrestricted" to isBatteryUnrestricted(),
                ))
            }
            "localFreeRamMb" -> result.success(ClusterWorkerService.availableRamMb(context))
            "localWifiIp" -> {
                acquireMulticastLock()
                result.success(resolveLocalWifiIpv4())
            }
            "setKeepScreenOn" -> {
                // A worker is only at full speed while PrivateLM is on screen
                // (it borrows the app's priority), so keep the screen on.
                val on = call.argument<Boolean>("on") == true
                activity?.runOnUiThread {
                    if (on) activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "requestBatteryUnrestricted" -> {
                // Android's own prompt; Samsung otherwise throttles a busy
                // worker in the background (slow cores, low CPU share).
                if (!isBatteryUnrestricted()) {
                    @Suppress("BatteryLife")
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(Uri.parse("package:${context.packageName}"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    runCatching { context.startActivity(intent) }.onFailure {
                        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(Uri.parse("package:${context.packageName}"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                }
                result.success(null)
            }
            "benchmark" -> scope.launch(Dispatchers.IO) {
                val gbps = ClusterNative.nativeMemBandwidth(ClusterNative.fastCoreCount())
                withContext(Dispatchers.Main) { result.success(gbps) }
            }
            "lastLoadBuffers" -> {
                val buffers = ClusterNative.nativeLastLoadBuffers().lines()
                    .mapNotNull { line ->
                        val name = line.substringBefore('\t', "").trim()
                        val mb = line.substringAfter('\t', "").trim().toDoubleOrNull()
                        if (name.isEmpty() || mb == null) null else mapOf("name" to name, "mb" to mb)
                    }
                result.success(buffers)
            }
            "discover" -> scope.launch {
                val found = try {
                    discover(call.argument<Int>("timeoutMs")?.toLong() ?: 4000L)
                } catch (e: Exception) {
                    Log.e(TAG, "Discovery failed", e)
                    withContext(Dispatchers.Main) { result.error("DISCOVERY_FAILED", e.message, null) }
                    return@launch
                }
                withContext(Dispatchers.Main) { result.success(found) }
            }
            "probe" -> scope.launch {
                val ok = probe(call.argument<String>("endpoint") ?: "", 2000)
                withContext(Dispatchers.Main) { result.success(ok) }
            }
            "setCluster" -> scope.launch {
                val endpoints = call.argument<List<String>>("endpoints") ?: emptyList()
                val weights = call.argument<List<Double>>("weights") ?: emptyList()
                val localWeight = call.argument<Double>("localWeight") ?: 1.0
                // llama.cpp aborts the whole app on an unreachable worker, so
                // refuse the cluster unless every worker answers right now.
                val unreachable = endpoints.filterNot { probe(it, 2000) }
                withContext(Dispatchers.Main) {
                    if (unreachable.isNotEmpty()) {
                        result.error("UNREACHABLE", "Can't reach ${unreachable.joinToString()}", null)
                        return@withContext
                    }
                    ClusterNative.nativeSetCluster(
                        endpoints.toTypedArray(),
                        FloatArray(endpoints.size) { weights.getOrNull(it)?.toFloat() ?: 1f },
                        localWeight.toFloat()
                    )
                    setLowLatencyWifi(endpoints.isNotEmpty())
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private var wifiLock: WifiManager.WifiLock? = null

    /**
     * Master: keep Wi-Fi out of power save while a cluster model is in use.
     * Every token makes a few round trips to the workers, and a dozing
     * radio adds tens of milliseconds to each.
     */
    private fun setLowLatencyWifi(on: Boolean) {
        if (on && wifiLock == null) {
            val wifi = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "PrivateLM:ClusterMaster").apply { acquire() }
        } else if (!on) {
            wifiLock?.takeIf { it.isHeld }?.release()
            wifiLock = null
        }
    }

    fun dispose() {
        runCatching { context.unbindService(workerPriority) }
        setLowLatencyWifi(false)
        runCatching {
            multicastLock?.takeIf { it.isHeld }?.release()
            multicastLock = null
        }
        channel.setMethodCallHandler(null)
    }

    /**
     * Resolves the device's LAN IPv4 address using Android's ConnectivityManager
     * and WifiManager APIs, which work on Android 11+ where SELinux blocks
     * Dart's NetworkInterface.list() (netlink getifaddrs).
     */
    private fun resolveLocalWifiIpv4(): String? {
        // 1. ConnectivityManager LinkProperties (preferred on Android 10+)
        runCatching {
            val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (cm != null) {
                val networks = mutableListOf<android.net.Network>()
                cm.activeNetwork?.let { networks.add(it) }
                @Suppress("DEPRECATION")
                cm.allNetworks.forEach { if (!networks.contains(it)) networks.add(it) }
                for (net in networks) {
                    val caps = cm.getNetworkCapabilities(net)
                    val isLan = caps == null ||
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                    if (!isLan) continue
                    val props = cm.getLinkProperties(net) ?: continue
                    for (linkAddr in props.linkAddresses) {
                        val addr = linkAddr.address
                        if (addr is Inet4Address && !addr.isLoopbackAddress) {
                            val host = addr.hostAddress ?: continue
                            if (host.startsWith("192.168.") || host.startsWith("10.") || host.startsWith("172.")) {
                                return host
                            }
                        }
                    }
                }
            }
        }

        // 2. WifiManager.connectionInfo fallback
        runCatching {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            val ipInt = wifi?.connectionInfo?.ipAddress ?: 0
            if (ipInt != 0) {
                val ip = String.format(
                    java.util.Locale.US,
                    "%d.%d.%d.%d",
                    ipInt and 0xff,
                    ipInt shr 8 and 0xff,
                    ipInt shr 16 and 0xff,
                    ipInt shr 24 and 0xff
                )
                if (ip != "0.0.0.0" && !ip.startsWith("127.")) {
                    return ip
                }
            }
        }

        // 3. Java NetworkInterface fallback
        runCatching {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return null
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                for (addr in iface.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val host = addr.hostAddress ?: continue
                        if (host.startsWith("192.168.") || host.startsWith("10.") || host.startsWith("172.")) {
                            return host
                        }
                    }
                }
            }
        }
        return null
    }

    private fun isBatteryUnrestricted(): Boolean {
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(context.packageName)
    }

    private fun isWorkerRunning(): Boolean {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val name = context.packageName + ClusterWorkerService.PROCESS_SUFFIX
        return am.runningAppProcesses?.any { it.processName == name } == true
    }

    private suspend fun probe(endpoint: String, timeoutMs: Int): Boolean = withContext(Dispatchers.IO) {
        val host = endpoint.substringBeforeLast(':')
        val port = endpoint.substringAfterLast(':').toIntOrNull() ?: return@withContext false
        try {
            Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Browses for workers for [timeoutMs], then resolves each one in turn. */
    private suspend fun discover(timeoutMs: Long): List<Map<String, Any?>> {
        val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val seen = mutableMapOf<String, NsdServiceInfo>()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(seen) { seen[info.serviceName] = info }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                synchronized(seen) { seen.remove(info.serviceName) }
            }
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, code: Int) {
                Log.e(TAG, "Discovery failed to start ($code)")
            }
            override fun onStopDiscoveryFailed(serviceType: String, code: Int) {}
        }
        nsd.discoverServices(ClusterWorkerService.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        try {
            delay(timeoutMs)
        } finally {
            try { nsd.stopServiceDiscovery(listener) } catch (e: IllegalArgumentException) {}
        }
        val candidates = synchronized(seen) { seen.values.toList() }
        // Older Android resolves one service at a time.
        return candidates.mapNotNull { resolve(nsd, it) }.map { info ->
            val attrs = info.attributes.mapValues { (_, v) -> v?.let { String(it) } }
            mapOf(
                "name" to info.serviceName,
                "host" to info.host?.hostAddress,
                "port" to info.port,
                "ramMb" to attrs["ram"]?.toLongOrNull(),
                "bandwidth" to attrs["bw"]?.toDoubleOrNull(),
                "model" to attrs["model"],
                "id" to attrs["id"],
                "version" to attrs["v"],
            )
        }.filter { it["host"] != null }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolve(nsd: NsdManager, info: NsdServiceInfo): NsdServiceInfo? =
        withTimeoutOrNull(3000) {
            suspendCancellableCoroutine { cont ->
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        if (cont.isActive) cont.resume(resolved)
                    }
                    override fun onResolveFailed(failed: NsdServiceInfo, code: Int) {
                        Log.w(TAG, "Resolve failed for ${failed.serviceName} ($code)")
                        if (cont.isActive) cont.resume(null)
                    }
                })
            }
        }
}
