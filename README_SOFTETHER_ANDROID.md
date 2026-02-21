SoftEther Native Integration (Android)

Overview

This project includes a scaffold for integrating a native SoftEther client into the Android app. The JNI/CMake scaffolding and `VpnService` skeleton are present, but a working native SoftEther library is required to establish a real OS-level tunnel.

Options to provide native support

1) Use prebuilt `.so` libraries (recommended if you have them)
   - Place compiled `.so` files under `android/app/src/main/jniLibs/<abi>/libsoftether_jni.so`.
   - Example ABI folders: `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`.
   - Ensure the library exports the JNI symbols expected in `softether_jni.cpp` or update the JNI code accordingly.

2) Build SoftEther client from source with NDK
   - This option compiles the SoftEther client code and the JNI glue into a shared library.
   - High level steps:
     a) Install Android NDK and CMake (match `ndkVersion` in `android/app/build.gradle`).
     b) Add SoftEther C sources to `android/app/src/main/cpp/softether/` or a submodule.
     c) Update `CMakeLists.txt` to build SoftEther sources and link into `softether_jni`.
     d) Implement JNI functions in `softether_jni.cpp` to call SoftEther client APIs.
     e) Build with Gradle: `./gradlew assembleDebug` (this will run CMake/Ninja to build native libs).

Important JNI functions

The scaffold expects these JNI entry points (Kotlin wrappers in `SoftEtherNative.kt` call these):
- `Java_com_example_hivpn_SoftEtherNative_nativeInit(JNIEnv*, jobject)
- `Java_com_example_hivpn_SoftEtherNative_nativePrepare(JNIEnv*, jobject)
- `Java_com_example_hivpn_SoftEtherNative_nativeConnect(JNIEnv*, jobject, jstring configJson)
- `Java_com_example_hivpn_SoftEtherNative_nativeDisconnect(JNIEnv*, jobject)
- `Java_com_example_hivpn_SoftEtherNative_nativeIsConnected(JNIEnv*, jobject)
- `Java_com_example_hivpn_SoftEtherNative_nativeGetStats(JNIEnv*, jobject)

`configJson` will be a JSON string containing fields from `SoftEtherConfig.toJson()`.

Android service

- `SoftEtherVpnService` is implemented as a skeleton VpnService that starts in foreground and will call native `connect` when a `softether_config_json` extra is present on the starting intent.
- Declare the service in `AndroidManifest.xml` with `android:permission="android.permission.BIND_VPN_SERVICE"` (already added).

Permissions & Play Store

- A native VPN implementation must use Android `VpnService` APIs and respect Play Store policies.
- Testing on devices requires granting VPN permission via `VpnService.prepare()` flow (handled by `MainActivity.handlePrepare`).

Testing locally

- If you don't have native libs yet, the app will fail SoftEther connections cleanly (no simulated success).
- To test the rest of the flow, you can place a small dummy `libsoftether_jni.so` that returns success for connect/isConnected.

Next steps I can take for you

- Integrate the SoftEther client (if you provide prebuilt `.so` files I can wire them into the repo and update JNI glue).
- Or I can write a detailed `CMakeLists.txt` and build instructions to compile SoftEther from sources into Android `.so` (this is more involved and I will need the source or permission to fetch it).

Which would you like? If you want me to implement native integration now, please provide prebuilt `.so` files or allow fetching/building SoftEther sources.