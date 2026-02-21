package com.example.hivpn

object SoftEtherNative {
    init {
        try {
            System.loadLibrary("softether_jni")
        } catch (e: UnsatisfiedLinkError) {
            // Library not available during development; methods will return defaults
        }
    }

    // native symbols (may be absent at runtime)
    private external fun nativeInitImpl(): Boolean
    private external fun nativePrepareImpl(): Boolean
    private external fun nativeConnectImpl(configJson: String): Boolean
    private external fun nativeDisconnectImpl(): Boolean
    private external fun nativeIsConnectedImpl(): Boolean
    private external fun nativeGetStatsImpl(): String

    // Safe wrappers to avoid throwing when native lib missing
    fun initialize(): Boolean {
        return try {
            nativeInitImpl()
        } catch (e: Throwable) {
            false
        }
    }

    fun prepare(): Boolean {
        return try {
            nativePrepareImpl()
        } catch (e: Throwable) {
            false
        }
    }

    fun connect(configJson: String): Boolean {
        return try {
            nativeConnectImpl(configJson)
        } catch (e: Throwable) {
            false
        }
    }

    fun disconnect(): Boolean {
        return try {
            nativeDisconnectImpl()
        } catch (e: Throwable) {
            false
        }
    }

    fun isConnected(): Boolean {
        return try {
            nativeIsConnectedImpl()
        } catch (e: Throwable) {
            false
        }
    }

    fun getStats(): String {
        return try {
            nativeGetStatsImpl()
        } catch (e: Throwable) {
            "{}"
        }
    }
}
