# Native SoftEther Integration Guide

## Current Status

The app now includes a **fully functional JNI stub** for SoftEther that compiles and runs end-to-end. The stub manages internal connection state and returns success, allowing users to:
- Select SoftEther as VPN type
- Configure SoftEther details
- "Connect" to SoftEther (shows as connected in the app UI)
- Health checks and session management work normally

## Important Note

**The current stub does NOT actually tunnel traffic.** It's a working scaffold that:
1. Compiles without external native libs
2. Allows the app to run fully (OpenVPN + SoftEther flows work)
3. Is ready to be replaced with real SoftEther client when native libs become available

## To Use the App Now

1. Build and run:
   ```bash
   flutter pub get
   flutter run
   ```

2. When prompted, grant VPN permission.

3. Select VPN type:
   - **OpenVPN**: Connects via `openvpn_flutter` plugin (real tunneling)
   - **SoftEther**: Uses the JNI stub (appears to connect, no traffic tunneling)

4. For testing: use OpenVPN to actually tunnel traffic; SoftEther selection/connection works but doesn't route traffic through a real tunnel.

## To Replace with Real SoftEther Native Library

When you have a real SoftEther client library:

### Option A: Prebuilt `.so` files

1. Obtain compiled `libsoftether_jni.so` for your target ABIs (arm64-v8a, armeabi-v7a, etc.).

2. Place them in:
   ```
   android/app/src/main/jniLibs/
   ├── arm64-v8a/
   │   └── libsoftether_jni.so
   ├── armeabi-v7a/
   │   └── libsoftether_jni.so
   └── (x86, x86_64, etc.)
   ```

3. Rebuild:
   ```bash
   cd android
   ./gradlew assembleDebug
   ```

### Option B: Build from SoftEther Sources

1. Obtain SoftEther C client sources or prebuilt client library.

2. Update `android/app/src/main/cpp/CMakeLists.txt` to include SoftEther sources and link them.

3. Implement the JNI functions in `softether_jni.cpp` to call the SoftEther client APIs:
   - `nativeConnect()`: Parse the JSON config, call SoftEther client connect APIs
   - `nativeIsConnected()`: Query SoftEther client connection status
   - `nativeDisconnect()`: Call SoftEther client disconnect
   - `nativeGetStats()`: Retrieve tunnel stats from SoftEther client

4. Implement `SoftEtherVpnService` TUN/VPN routing:
   - Use Android `VpnService.Builder` to set up a TUN device
   - Route app traffic through the TUN to the SoftEther tunnel
   - Proper route and DNS configuration

5. Rebuild:
   ```bash
   flutter run
   ```

## JNI Symbol Reference

All JNI functions are in `android/app/src/main/cpp/softether_jni.cpp`:

- `nativeInitImpl()` → initializes the native client
- `nativePrepareImpl()` → checks prerequisites
- `nativeConnectImpl(configJson)` → connects with SoftEther config (JSON string)
- `nativeDisconnectImpl()` → disconnects
- `nativeIsConnectedImpl()` → returns connection state
- `nativeGetStatsImpl()` → returns stats JSON

These are called safely via Kotlin wrappers (`SoftEtherNative.kt`) which catch exceptions if the library is missing.

## Files Modified for Native Integration

- `lib/platform/softether_channel.dart` — Dart platform channel wrapper
- `android/app/src/main/kotlin/com/example/hivpn/SoftEtherNative.kt` — Kotlin JNI wrapper
- `android/app/src/main/kotlin/com/example/hivpn/SoftEtherVpnService.kt` — VpnService skeleton
- `android/app/src/main/cpp/softether_jni.cpp` — C++ JNI implementation (currently stub)
- `android/app/src/main/cpp/CMakeLists.txt` — NDK build configuration
- `android/app/build.gradle` — Gradle config with externalNativeBuild
- `android/app/src/main/AndroidManifest.xml` — SoftEtherVpnService declaration
- `android/app/src/main/kotlin/com/example/hivpn/NotificationUtils.kt` — Foreground notification helper

## Next Steps

1. **Test the app locally** with the stub. OpenVPN tunnels real traffic; SoftEther shows as connected but doesn't tunnel.

2. **Obtain real SoftEther native library**:
   - Download prebuilt SoftEther client for Android NDK, or
   - Build SoftEther from source with Android NDK

3. **Integrate the real library**:
   - Replace stub JNI functions with real SoftEther client calls
   - Wire up proper VPN routing in `SoftEtherVpnService`
   - Test on device

## Support

If you encounter:
- **JNI symbol mismatch**: Check function names in `softether_jni.cpp` match `SoftEtherNative.kt` method names
- **Library load failure**: Ensure `.so` is in correct ABI folder or CMake builds successfully
- **Connection failures**: Add detailed logging in JNI functions to diagnose issues

