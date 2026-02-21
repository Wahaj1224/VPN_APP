package com.example.hivpn

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import com.example.hivpn.vpn.HiVpnTileService
import org.json.JSONObject
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin

class MainActivity : FlutterActivity() {
    private val channelName = "com.example.vpn/VpnChannel"
    private val prepareRequestCode = 1001
    private var prepareResult: MethodChannel.Result? = null
    private var pendingExtendIntent = false
    private lateinit var methodChannel: MethodChannel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntentAction(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> handlePrepare(result)
                "getInstalledApps" -> result.success(fetchInstalledApps())
                "updateQuickTile" -> {
                    HiVpnTileService.requestTileUpdate(this)
                    result.success(null)
                }
                "elapsedRealtime" -> result.success(SystemClock.elapsedRealtime())
                else -> result.notImplemented()
            }
        }

            // SoftEther native channel (scaffold). Returns false/empty by default
            val softEtherChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hivpn/softether")
            softEtherChannel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "initialize" -> {
                            Log.d("MainActivity", "SoftEther initialize called")
                            val ok = SoftEtherNative.initialize()
                            result.success(ok)
                        }
                        "prepare" -> {
                            Log.d("MainActivity", "SoftEther prepare called")
                            // Reuse existing prepare flow
                            handlePrepare(result)
                        }
                        "connect" -> {
                            Log.d("MainActivity", "SoftEther connect called")
                            val args = call.arguments
                            val configJson = if (args is Map<*, *>) {
                                // If Dart passed a Map, convert to JSON string
                                org.json.JSONObject(args as Map<*, *>).toString()
                            } else if (args is String) {
                                args
                            } else {
                                null
                            }

                            if (configJson != null) {
                                val intent = Intent(this, SoftEtherVpnService::class.java)
                                intent.putExtra("softether_config_json", configJson)
                                // Start the service (foreground service required for long-running VPN)
                                startService(intent)
                                result.success(true)
                            } else {
                                result.error("invalid_args", "Missing SoftEther config", null)
                            }
                        }
                        "disconnect" -> {
                            Log.d("MainActivity", "SoftEther disconnect called")
                            val stopped = stopService(Intent(this, SoftEtherVpnService::class.java))
                            // Also call native disconnect if available
                            try {
                                SoftEtherNative.disconnect()
                            } catch (e: Throwable) {
                                Log.w("MainActivity", "Native disconnect failed: ${e.message}")
                            }
                            result.success(stopped)
                        }
                        "isConnected" -> {
                            // CRITICAL FIX: Only trust the native tunnel status
                            // Don't rely on service running flags which just mean the service started
                            // The native status tells us if the actual tunnel to remote server is connected
                            val nativeConnected = SoftEtherNative.isConnected()
                            Log.d("MainActivity", "SoftEther isConnected: $nativeConnected (serviceConnected: ${SoftEtherVpnService.isConnected}, serviceRunning: ${SoftEtherVpnService.isServiceRunning}, nativeConnected: $nativeConnected)")
                            result.success(nativeConnected)
                        }
                        "getStats" -> {
                            val stats = SoftEtherNative.getStats()
                            result.success(stats)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e("MainActivity", "SoftEther channel error: $e")
                    result.error("error", e.message, null)
                }
            }

        if (pendingExtendIntent) {
            methodChannel.invokeMethod("notifyIntentAction", ACTION_SHOW_EXTEND_AD)
            dispatchExtendRequest()
        } else {
            handleIntentAction(intent)
        }
    }

    private fun handlePrepare(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            prepareResult = result
            startActivityForResult(intent, prepareRequestCode)
        } else {
            result.success(true)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // OpenVPN permission handler
        OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK)

        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == prepareRequestCode) {
            prepareResult?.success(resultCode == RESULT_OK)
            prepareResult = null
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntentAction(intent)
    }

    private fun handleIntentAction(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return

        if (!::methodChannel.isInitialized) {
            if (action == ACTION_SHOW_EXTEND_AD) {
                pendingExtendIntent = true
            }
            return
        }

        methodChannel.invokeMethod("notifyIntentAction", action)

        if (action == ACTION_SHOW_EXTEND_AD) {
            dispatchExtendRequest()
        }
    }

    private fun dispatchExtendRequest() {
        if (::methodChannel.isInitialized) {
            methodChannel.invokeMethod("showExtendAd", null)
            pendingExtendIntent = false
        } else {
            pendingExtendIntent = true
        }
    }

    private fun fetchInstalledApps(): List<Map<String, String>> {
        val pm = packageManager
        val apps = pm.getInstalledApplications(0)
        return apps
            .filter { pm.getLaunchIntentForPackage(it.packageName) != null }
            .map {
                mapOf(
                    "package" to it.packageName,
                    "name" to pm.getApplicationLabel(it).toString(),
                )
            }
            .sortedBy { it["name"] }
    }

    companion object {
        const val ACTION_SHOW_EXTEND_AD = "com.example.hivpn.action.SHOW_EXTEND_AD"
    }
}
