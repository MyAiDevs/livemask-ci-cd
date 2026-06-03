# Flutter VPN Integration Patterns

> Supplement document — Flutter VPN client integration with sing-box via gomobile
> Source: livemask-app implementation + community patterns

## Architecture Flow

```
Flutter UI (Dart)
    ↓ MethodChannel ('com.livemask/vpn')
Platform Native (Kotlin/Swift)
    ↓ VpnService (Android) / PacketTunnelProvider (iOS)
TUN File Descriptor
    ↓ fd passed to Go engine
sing-box Engine (Go, via gomobile AAR)
    ↓ proxy connection
VPN Server
```

## Android VpnService Integration

```kotlin
// Android native
class LiveMaskVpnService : VpnService() {
    private fun setupTun(): ParcelFileDescriptor {
        return Builder()
            .setMtu(1500)
            .addAddress("10.0.0.2", 32)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
            .establish()
    }
}
```

## Flutter Platform Channel

```dart
class VpnChannel {
  static const channel = MethodChannel('com.livemask/vpn');

  static Future<bool> connect(Map<String, dynamic> config) async {
    return await channel.invokeMethod('connect', config);
  }

  static Future<bool> disconnect() async {
    return await channel.invokeMethod('disconnect');
  }

  static Stream<Map<String, dynamic>> get statusStream {
    return EventChannel('com.livemask/vpn/status')
        .receiveBroadcastStream()
        .cast<Map<String, dynamic>>();
  }
}
```

## Build & Dependencies

1. Gomobile AAR: `gomobile bind -target=android/arm64 -o android/app/libs/engine.aar ./pkg/mobile/`
2. Add to android/app/build.gradle: `implementation files('libs/engine.aar')`
3. iOS framework: `gomobile bind -target=ios -o ios/Frameworks/Engine.framework ./pkg/mobile/`
4. iOS must disable bitcode for gomobile frameworks
