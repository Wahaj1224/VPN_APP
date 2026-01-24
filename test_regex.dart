void main() {
  final content = '''-----BEGIN OpenVPN Static key V1-----
8d308485bb9eb189a9db5c146dd96464
7dd70589f619bb95c6a46b3ea230656a
-----END OpenVPN Static key V1-----''';

  final keyPattern = RegExp(
    r'-----BEGIN\s+OpenVPN\s+Static\s+key\s+V1-----(.+?)-----END\s+OpenVPN\s+Static\s+key\s+V1-----',
    multiLine: true,
    dotAll: true,
    caseSensitive: false,
  );

  final match = keyPattern.firstMatch(content);
  print('Match found: ${match != null}');
  if (match != null) {
    print('Full match: ${match.group(0)}');
    print('Group 1: ${match.group(1)}');
  } else {
    print('No match found');
    print('Testing simpler pattern...');
    final simplePattern = RegExp(
      r'-----BEGIN OpenVPN Static key V1-----',
      caseSensitive: false,
    );
    print('Simple BEGIN pattern matches: ${simplePattern.hasMatch(content)}');
  }
}
