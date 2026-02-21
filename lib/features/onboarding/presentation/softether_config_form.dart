import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/vpn/models/vpn_type.dart';
import '../../../services/vpn/models/softether_config.dart';
import '../../../services/vpn/vpn_selection_provider.dart';
import '../../../theme/colors.dart';

class SoftEtherConfigForm extends ConsumerStatefulWidget {
  final Function(SoftEtherConfig) onConfigChanged;

  const SoftEtherConfigForm({
    super.key,
    required this.onConfigChanged,
  });

  @override
  ConsumerState<SoftEtherConfigForm> createState() =>
      _SoftEtherConfigFormState();
}

class _SoftEtherConfigFormState extends ConsumerState<SoftEtherConfigForm> {
  late TextEditingController _connectionNameController;
  late TextEditingController _serverAddressController;
  late TextEditingController _serverPortController;
  late TextEditingController _presharedKeyController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;

  VpnProtocol _selectedProtocol = VpnProtocol.l2tpIpsec;
  bool _showPassword = false;
  bool _showPresharedKey = false;

  @override
  void initState() {
    super.initState();
    _connectionNameController = TextEditingController();
    _serverAddressController = TextEditingController();
    _serverPortController = TextEditingController();
    _presharedKeyController = TextEditingController();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadExistingConfig();
  }

  void _loadExistingConfig() {
    final existingConfig = ref.read(softEtherConfigProvider);
    if (existingConfig != null) {
      _connectionNameController.text = existingConfig.connectionName;
      _serverAddressController.text = existingConfig.serverAddress;
      _serverPortController.text = existingConfig.serverPort.toString();
      _presharedKeyController.text = existingConfig.presharedKey ?? '';
      _usernameController.text = existingConfig.username;
      _passwordController.text = existingConfig.password;
      _selectedProtocol = existingConfig.protocol;
    } else {
      // Set defaults if no existing config
      _connectionNameController.text = 'wahaj';
      _serverAddressController.text = '100.28.211.202';
      _serverPortController.text = '1701'; // L2TP/IPSec default port
      _presharedKeyController.text = 'vpn123';
      _usernameController.text = 'wahaj';
      _passwordController.text = 'wahaj';
      _selectedProtocol = VpnProtocol.l2tpIpsec;
    }
  }

  @override
  void dispose() {
    _connectionNameController.dispose();
    _serverAddressController.dispose();
    _serverPortController.dispose();
    _presharedKeyController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _updateConfig() {
    final port = int.tryParse(_serverPortController.text) ?? 5555;
    final config = SoftEtherConfig(
      connectionName: _connectionNameController.text,
      serverAddress: _serverAddressController.text,
      serverPort: port,
      protocol: _selectedProtocol,
      presharedKey: _presharedKeyController.text,
      username: _usernameController.text,
      password: _passwordController.text,
    );
    widget.onConfigChanged(config);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Connection Name
        _buildTextField(
          label: 'Connection Name',
          controller: _connectionNameController,
          hint: 'e.g., My VPN Connection',
          onChanged: (_) => _updateConfig(),
        ),
        const SizedBox(height: 16),

        // Server Address
        _buildTextField(
          label: 'Server Address',
          controller: _serverAddressController,
          hint: 'IP or hostname',
          onChanged: (_) => _updateConfig(),
        ),
        const SizedBox(height: 16),

        // Server Port
        _buildTextField(
          label: 'Server Port',
          controller: _serverPortController,
          hint: '5555',
          keyboardType: TextInputType.number,
          onChanged: (_) => _updateConfig(),
        ),
        const SizedBox(height: 16),

        // VPN Protocol Dropdown
        _buildDropdown(
          label: 'VPN Protocol Type',
          value: _selectedProtocol,
          items: VpnProtocol.values.toList(),
          onChanged: (newValue) {
            if (newValue != null) {
              setState(() => _selectedProtocol = newValue);
              _updateConfig();
            }
          },
        ),
        const SizedBox(height: 16),

        // Pre-shared Key (L2TP/IPSec only)
        if (_selectedProtocol == VpnProtocol.l2tpIpsec)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTextField(
                label: 'Pre-Shared Key',
                controller: _presharedKeyController,
                hint: 'Enter pre-shared key',
                obscureText: !_showPresharedKey,
                suffixIcon: IconButton(
                  icon: Icon(
                    _showPresharedKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () {
                    setState(
                        () => _showPresharedKey = !_showPresharedKey);
                  },
                ),
                onChanged: (_) => _updateConfig(),
              ),
              const SizedBox(height: 16),
            ],
          ),

        // Username
        _buildTextField(
          label: 'Username',
          controller: _usernameController,
          hint: 'VPN username',
          onChanged: (_) => _updateConfig(),
        ),
        const SizedBox(height: 16),

        // Password
        _buildTextField(
          label: 'Password',
          controller: _passwordController,
          hint: 'VPN password',
          obscureText: !_showPassword,
          suffixIcon: IconButton(
            icon: Icon(
              _showPassword ? Icons.visibility : Icons.visibility_off,
            ),
            onPressed: () {
              setState(() => _showPassword = !_showPassword);
            },
          ),
          onChanged: (_) => _updateConfig(),
        ),

        const SizedBox(height: 16),

        // Info Box
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: HiVpnColors.accent.withOpacity(0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: HiVpnColors.accent.withOpacity(0.2),
              width: 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                color: HiVpnColors.accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Make sure the server is reachable and all credentials are correct.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required String hint,
    TextInputType keyboardType = TextInputType.text,
    bool obscureText = false,
    Widget? suffixIcon,
    Function(String)? onChanged,
  }) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscureText,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: suffixIcon,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown({
    required String label,
    required VpnProtocol value,
    required List<VpnProtocol> items,
    required Function(VpnProtocol?) onChanged,
  }) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<VpnProtocol>(
          value: value,
          items: items
              .map((item) => DropdownMenuItem(
                    value: item,
                    child: Text(item.displayName),
                  ))
              .toList(),
          onChanged: onChanged,
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
        ),
      ],
    );
  }
}
