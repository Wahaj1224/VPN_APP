package com.example.hivpn

import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONObject
import java.io.*
import java.net.Socket

/**
 * SoftEther VPN Service with packet routing
 * Routes all traffic through VPN interface with public DNS
 */
class SoftEtherVpnService : VpnService() {
    private val TAG = "SoftEtherVpnService"
    private var vpnThread: Thread? = null
    private var tunnelInputThread: Thread? = null
    private var running = false
    
    companion object {
        @Volatile
        var isConnected = false
        
        @Volatile
        var isServiceRunning = false
    }

    override fun onBind(intent: Intent?): IBinder? {
        return super.onBind(intent)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "🚀 SoftEtherVpnService started")
        isServiceRunning = true

        try {
            val notif = NotificationUtils.buildForegroundNotification(this, "🔐 SoftEther VPN Connecting...")
            startForeground(1001, notif)
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to start foreground: ${e.message}")
        }

        // Parse config and establish VPN connection
        val configJson = intent?.getStringExtra("softether_config_json")
        if (configJson != null) {
            running = true
            vpnThread = Thread {
                try {
                    val config = JSONObject(configJson)
                    establishVpnTunnel(config)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to establish VPN: ${e.message}", e)
                    isConnected = false
                    running = false
                    stopSelf()
                }
            }
            vpnThread?.start()
        } else {
            Log.w(TAG, "No config provided")
            stopSelf()
        }

        return Service.START_STICKY
    }

    private fun establishVpnTunnel(config: JSONObject) {
        try {
            val serverAddress = config.getString("serverAddress")
            val serverPort = config.getInt("serverPort")
            val connectionName = config.getString("connectionName")
            
            Log.d(TAG, "🌐 Establishing VPN tunnel to $serverAddress:$serverPort")

            // Create VPN interface builder
            val builder = Builder()
            builder.setSession(connectionName)
            
            // Assign VPN interface an IP address
            builder.addAddress("10.8.0.1", 24)
            
            // Add public DNS servers (no local server needed)
            try {
                builder.addDnsServer("8.8.8.8")       // Google DNS
                builder.addDnsServer("8.8.4.4")       // Google DNS Secondary
                builder.addDnsServer("1.1.1.1")       // Cloudflare DNS
                Log.d(TAG, "✅ DNS servers configured: 8.8.8.8, 8.8.4.4, 1.1.1.1")
            } catch (e: Exception) {
                Log.w(TAG, "Could not add DNS servers: ${e.message}")
            }
            
            // Route all traffic through VPN
            try {
                builder.addRoute("0.0.0.0", 0)
                Log.d(TAG, "✅ Default route configured (0.0.0.0/0)")
            } catch (e: Exception) {
                Log.w(TAG, "Could not add default route: ${e.message}")
            }
            
            // IPv6 support
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    builder.addAddress("fd00::1", 64)
                    builder.addRoute("::", 0)
                    Log.d(TAG, "✅ IPv6 configured")
                } catch (e: Exception) {
                    Log.w(TAG, "IPv6 setup failed: ${e.message}")
                }
            }
            
            builder.setMtu(1500)
            
            // Don't exclude this app - we want it to use the VPN
            try {
                builder.addDisallowedApplication("com.android.systemui")
                builder.addDisallowedApplication("com.android.settings")
            } catch (e: Exception) {
                Log.w(TAG, "Could not set disallowed apps: ${e.message}")
            }

            // Establish the VPN interface
            val vpnInterface = builder.establish()
            
            if (vpnInterface != null) {
                Log.d(TAG, "✅ VPN interface established successfully")
                isConnected = true
                
                // Handle VPN traffic with proper packet routing
                handleVpnPackets(vpnInterface, serverAddress, serverPort)
            } else {
                Log.e(TAG, "❌ Failed to establish VPN interface")
                isConnected = false
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ VPN tunnel setup failed: ${e.message}", e)
            isConnected = false
        } finally {
            cleanup()
            stopSelf()
        }
    }

    private fun handleVpnPackets(vpnInterface: android.os.ParcelFileDescriptor, 
                                  serverAddress: String, serverPort: Int) {
        try {
            val fd = vpnInterface.fileDescriptor
            val tunInput = FileInputStream(fd)
            val tunOutput = FileOutputStream(fd)
            
            Log.d(TAG, "📊 Starting packet handling - processing traffic")
            
            // Try to establish tunnel connection - this is critical for VPN functionality
            var tunnelSocket: Socket? = null
            var hasTunnel = false
            var tunnelInputThread: Thread? = null
            var connectionError: Exception? = null
            
            // Synchronous tunnel connection attempt
            try {
                Log.d(TAG, "🔗 Attempting to connect to $serverAddress:$serverPort...")
                tunnelSocket = Socket()
                try {
                    // Protect the socket so it bypasses the VPN routing and uses the underlying network
                    protect(tunnelSocket)
                    Log.d(TAG, "🔐 Tunnel socket protected from VPN routing")
                } catch (pe: Exception) {
                    Log.w(TAG, "⚠️ Failed to protect tunnel socket: ${pe.message}")
                    throw pe
                }
                tunnelSocket?.connect(java.net.InetSocketAddress(serverAddress, serverPort), 5000) // Increased timeout
                hasTunnel = true
                isConnected = true // Set connected status only after successful tunnel establishment
                Log.d(TAG, "✅ SUCCESS: Connected to tunnel server!")
                
                // Update notification to show connected status
                try {
                    val connectedNotif = NotificationUtils.buildForegroundNotification(this, "🔐 SoftEther VPN Connected")
                    startForeground(1001, connectedNotif)
                } catch (e: Throwable) {
                    Log.w(TAG, "Failed to update notification: ${e.message}")
                }
                
                // Start a thread to read from tunnel socket and write to VPN interface
                tunnelInputThread = Thread {
                    val tunnelBuffer = ByteArray(32768)
                    try {
                        while (running && tunnelSocket?.isConnected == true) {
                            val len = tunnelSocket?.getInputStream()?.read(tunnelBuffer)
                            if (len != null && len > 0) {
                                tunOutput.write(tunnelBuffer, 0, len)
                                tunOutput.flush()
                            } else if (len == -1) {
                                // End of stream
                                break
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Tunnel input thread error: ${e.message}")
                        if (running) {
                            connectionError = e
                        }
                    }
                    Log.d(TAG, "🛑 Tunnel input thread stopped")
                }
                tunnelInputThread?.start()
            } catch (e: Exception) {
                Log.e(TAG, "❌ CRITICAL: Failed to establish tunnel to $serverAddress:$serverPort: ${e.message}")
                Log.e(TAG, "   This means the SoftEther server is not reachable or not configured properly")
                Log.e(TAG, "   Possible causes:")
                Log.e(TAG, "   - Server is not running")
                Log.e(TAG, "   - Firewall blocking port $serverPort")
                Log.e(TAG, "   - Wrong server address or port")
                Log.e(TAG, "   - Network connectivity issues")
                Log.e(TAG, "   Stopping VPN service due to tunnel failure")
                connectionError = e
                hasTunnel = false
                // Stop the service immediately since we can't establish a tunnel
                running = false
                stopSelf()
                return
            }
            
            val buffer = ByteArray(32768)
            var totalPackets = 0
            var dnsResponses = 0
            
            while (running && connectionError == null) {
                try {
                    val len = tunInput.read(buffer)
                    if (len > 0) {
                        totalPackets++
                        
                        // Check if this is a DNS query (port 53)
                        if (isDnsPacket(buffer, len)) {
                            dnsResponses++
                            // Respond to DNS queries
                            val response = buildDnsResponse(buffer, len)
                            tunOutput.write(response)
                            tunOutput.flush()
                        } else if (hasTunnel && tunnelSocket != null && tunnelSocket.isConnected) {
                            // Forward to tunnel server
                            try {
                                tunnelSocket.getOutputStream().write(buffer, 0, len)
                                tunnelSocket.getOutputStream().flush()
                            } catch (e: Exception) {
                                Log.w(TAG, "Tunnel write failed: ${e.message}")
                                hasTunnel = false
                            }
                        } else {
                            // Local loopback mode - just echo packet
                            tunOutput.write(buffer, 0, len)
                            tunOutput.flush()
                        }
                        
                        // Log statistics
                        if (totalPackets % 500 == 0) {
                            val status = if (hasTunnel && tunnelSocket?.isConnected == true) "🔗 TUNNEL ACTIVE" else "🔄 LOCAL MODE"
                            Log.d(TAG, "📈 Stats: $totalPackets packets, $dnsResponses DNS responses [$status]")
                        }
                    }
                } catch (e: Exception) {
                    if (running) {
                        Log.e(TAG, "Packet error: ${e.message}")
                    }
                    break
                }
            }
            
            Log.d(TAG, "🛑 Packet handling stopped: $totalPackets packets, $dnsResponses DNS responses")
            tunnelSocket?.close()
            
        } catch (e: Exception) {
            Log.e(TAG, "Packet handling failed: ${e.message}", e)
        }
    }
    
    private fun isDnsPacket(buffer: ByteArray, len: Int): Boolean {
        if (len < 28) return false
        // Check for DNS port (port 53) in the IP packet
        // This is a simplified check - looks for UDP with destination port 53
        return try {
            // UDP port check (IP header is 20 bytes for IPv4)
            val destPort = ((buffer[22].toInt() and 0xFF) shl 8) or (buffer[23].toInt() and 0xFF)
            destPort == 53
        } catch (e: Exception) {
            false
        }
    }
    
    private fun buildDnsResponse(buffer: ByteArray, len: Int): ByteArray {
        // Build a simple DNS response
        val response = ByteArray(len)
        System.arraycopy(buffer, 0, response, 0, len)
        
        // Set response flag (bit 15 of flags field)
        if (len > 2) {
            response[2] = (response[2].toInt() or 0x80).toByte()
            response[3] = (response[3].toInt() or 0x80).toByte()
        }
        
        return response
    }

    private fun cleanup() {
        running = false
        try {
            tunnelInputThread?.interrupt()
        } catch (e: Exception) {
            Log.w(TAG, "Error interrupting tunnel input thread: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "🛑 SoftEtherVpnService destroyed")
        running = false
        isConnected = false
        isServiceRunning = false
        cleanup()
        try {
            vpnThread?.interrupt()
        } catch (e: Exception) {
            Log.w(TAG, "Error interrupting thread: ${e.message}")
        }
    }
}
