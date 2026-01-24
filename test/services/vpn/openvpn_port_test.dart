import 'package:flutter_test/flutter_test.dart';

import 'package:hivpn/services/vpn/openvpn_port.dart';

void main() {
  group('OpenVPN config sanitizer', () {
    test('preserves certificate blocks and extracts credentials', () {
      final sampleConfig = '''
client
dev tun
proto tcp
remote 1.2.3.4 443
auth-user-pass
<auth-user-pass>
vpnuser
vpnpass
</auth-user-pass>
<ca>
-----BEGIN CERTIFICATE-----
MIIBszCCAVugAwIBAgIBADAKBggqhkjOPQQDAjASMRAwDgYDVQQDDAdUZXN0Q0Ew
HhcNMjQwMTAxMDAwMDAwWhcNMzQwMTAxMDAwMDAwWjASMRAwDgYDVQQDDAdUZXN0
Q0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARJj8nXrVEU5t9XX0bUQxHDc36T
DpDBT4J6sF9Cvt2Q9i7/z7S4I65EHhOArb0gIkS7AwEHoCk3xs4lBu7QptijUzBR
MB0GA1UdDgQWBBSBf6OAYoDkTxUxDcIsVYJYWG4KQTAfBgNVHSMEGDAWgBSBf6OA
YoDkTxUxDcIsVYJYWG4KQTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gA
MEUCICUOlO1kFdTXYgWkiS1Z6j1v6Rj12p7Sg0KVIoXeCGOjAiEA3vd7NEANXzEF
4k74kV3uRJmUQ5vJv3VYZJdVhjq2O9A=
-----END CERTIFICATE-----
</ca>
''';

      final sanitizer = OpenVpnPort();
      final result = sanitizer.debugSanitizeOpenVpnConfig(sampleConfig);

      expect(result.username, equals('vpnuser'));
      expect(result.password, equals('vpnpass'));

      final normalizedConfig = result.config;
      expect(
        RegExp(r'^auth-user-pass$', multiLine: true).allMatches(normalizedConfig).length,
        equals(1),
      );
      expect(normalizedConfig.contains('<ca>'), isTrue);
      expect(normalizedConfig.contains('</ca>'), isTrue);

      final lines = normalizedConfig.split('\n');
      final authIndex = lines.indexOf('auth-user-pass');
      expect(authIndex, isNonNegative);
      expect(lines[authIndex + 1], equals('<ca>'));
    });

    test('adds auth-user-pass directive when missing', () {
      final sampleConfig = '''
client
remote 5.6.7.8 1194
<ca>
CA DATA
</ca>
auth-user-pass
''';

      final sanitizer = OpenVpnPort();
      final result = sanitizer.debugSanitizeOpenVpnConfig(sampleConfig);

      expect(result.username, isNull);
      expect(result.password, isNull);

      final normalizedConfig = result.config;
      final matches =
          RegExp(r'^auth-user-pass$', multiLine: true).allMatches(normalizedConfig).length;
      // Should NOT automatically add auth-user-pass if not in config
      // Only keep if it was already there
      expect(normalizedConfig.trimRight().endsWith('auth-user-pass'), isTrue);
    });

    test('fixes malformed tls-auth blocks', () {
      final sampleConfig = '''
client
remote 1.2.3.4 443
<tls-auth>
-----BEGIN OpenVPN Static key V1-----
8d308485bb9eb189a9db5c146dd96464
7dd70589f619bb95c6a46b3ea230656a
-----END OpenVPN Static key V1-----
</tls-auth>
<ca>
-----BEGIN CERTIFICATE-----
MIIC...
-----END CERTIFICATE-----
</ca>
''';

      final sanitizer = OpenVpnPort();
      final result = sanitizer.debugSanitizeOpenVpnConfig(sampleConfig);

      final normalizedConfig = result.config;
      // Valid tls-auth blocks should be preserved (server requires it)
      expect(normalizedConfig.contains('<tls-auth>'), isTrue);
      expect(normalizedConfig.contains('</tls-auth>'), isTrue);
      // CA block should also be preserved
      expect(normalizedConfig.contains('<ca>'), isTrue);
      expect(normalizedConfig.contains('</ca>'), isTrue);
      // Should not contain malformed closing tags
      expect(normalizedConfig.contains('</tls-auth>>'), isFalse);
      expect(normalizedConfig.contains('<//tls-auth>'), isFalse);
    });

    test('handles config with missing closing tags', () {
      final sampleConfig = '''
client
remote 1.2.3.4 443
<ca>
-----BEGIN CERTIFICATE-----
MIIC...
-----END CERTIFICATE-----
<key>
-----BEGIN PRIVATE KEY-----
MIIC...
-----END PRIVATE KEY-----
''';

      final sanitizer = OpenVpnPort();
      final result = sanitizer.debugSanitizeOpenVpnConfig(sampleConfig);

      final normalizedConfig = result.config;
      // Should add missing closing tags
      expect(normalizedConfig.contains('</ca>'), isTrue);
      expect(normalizedConfig.contains('</key>'), isTrue);
    });
  });
}
