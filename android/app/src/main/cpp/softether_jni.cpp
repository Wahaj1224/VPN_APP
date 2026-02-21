#include <jni.h>
#include <string>
#include <android/log.h>

#define LOG_TAG "softether_jni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Internal state for the native SoftEther client stub
static bool g_initialized = false;
static bool g_connected = false;
static std::string g_lastConfig = "{}";

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_hivpn_SoftEtherNative_nativeInitImpl(JNIEnv* env, jobject /* this */) {
    LOGI("nativeInit called");
    g_initialized = true;
    g_connected = false;
    return JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_hivpn_SoftEtherNative_nativePrepareImpl(JNIEnv* env, jobject /* this */) {
    LOGI("nativePrepare called");
    if (!g_initialized) {
        LOGE("Not initialized");
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_hivpn_SoftEtherNative_nativeConnectImpl(JNIEnv* env, jobject /* this */, jstring configJson) {
    if (!g_initialized) {
        LOGE("Not initialized for connect");
        return JNI_FALSE;
    }

    const char* configStr = env->GetStringUTFChars(configJson, nullptr);
    if (!configStr) {
        LOGE("Failed to get config string");
        return JNI_FALSE;
    }

    LOGI("nativeConnect called with config: %s", configStr);
    g_lastConfig = std::string(configStr);
    env->ReleaseStringUTFChars(configJson, configStr);

    // Simulate connection (in real implementation, this would call SoftEther client APIs)
    g_connected = true;
    LOGI("Connection established (stub)");

    return JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_hivpn_SoftEtherNative_nativeDisconnectImpl(JNIEnv* env, jobject /* this */) {
    LOGI("nativeDisconnect called");
    g_connected = false;
    return JNI_TRUE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_hivpn_SoftEtherNative_nativeIsConnectedImpl(JNIEnv* env, jobject /* this */) {
    LOGI("nativeIsConnected called, state: %s", g_connected ? "true" : "false");
    return g_connected ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_hivpn_SoftEtherNative_nativeGetStatsImpl(JNIEnv* env, jobject /* this */) {
    LOGI("nativeGetStats called");
    std::string stats = "{\"status\":\"" + std::string(g_connected ? "connected" : "disconnected") + "\"}";
    return env->NewStringUTF(stats.c_str());
}

