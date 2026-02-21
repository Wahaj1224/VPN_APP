# EC2 SoftEther VPN API Integration Guide

## Current State
The Flutter app is ready with:
- ✅ VPN type selection UI
- ✅ SoftEther configuration form
- ✅ Connection routing to SoftEther handler
- ⏳ **Placeholder/Simulation**: SoftEther connection is currently simulated

## What You Need to Do

### Phase 1: Create EC2 Node.js API Server

Your EC2 server needs a Node.js API that acts as a bridge between Flutter app and vpncmd.

#### 1. Install Node.js on EC2
```bash
# Update system
sudo apt update
sudo apt upgrade -y

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs npm

# Verify installation
node --version
npm --version
```

#### 2. Create Node.js API Server

Create a new directory structure:
```
/home/ec2-user/softether-api/
├── app.js
├── package.json
├── routes/
│   └── vpn.js
├── controllers/
│   └── vpnController.js
└── config/
    └── vpn-config.js
```

#### 3. Initialize Node.js Project

```bash
mkdir -p ~/softether-api
cd ~/softether-api
npm init -y
npm install express cors body-parser dotenv axios child-process-promise
```

#### 4. Create app.js

```javascript
const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 8000;

// Middleware
app.use(cors());
app.use(bodyParser.json());

// Import routes
const vpnRoutes = require('./routes/vpn');

// Routes
app.use('/api/softether', vpnRoutes);

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'API is running', timestamp: new Date() });
});

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({ 
    success: false, 
    error: err.message || 'Internal server error' 
  });
});

app.listen(PORT, () => {
  console.log(`SoftEther VPN API listening on port ${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/health`);
});

module.exports = app;
```

#### 5. Create routes/vpn.js

```javascript
const express = require('express');
const router = express.Router();
const vpnController = require('../controllers/vpnController');

// VPN Connection endpoints
router.post('/connect', vpnController.createConnection);
router.post('/disconnect', vpnController.disconnectConnection);
router.get('/status/:connectionName', vpnController.getConnectionStatus);
router.get('/list', vpnController.listConnections);

module.exports = router;
```

#### 6. Create controllers/vpnController.js

```javascript
const { exec } = require('child-process-promise');
const path = require('path');

class VpnController {
  constructor() {
    // Path to vpncmd on your EC2 server
    this.vpncmdPath = '/usr/bin/vpncmd';
    this.vpnServerAddress = 'localhost:5555';
    this.vpnPassword = 'admin';
  }

  /**
   * Create VPN connection using vpncmd
   * POST /api/softether/connect
   */
  async createConnection(req, res) {
    try {
      const {
        connectionName,
        serverAddress,
        serverPort,
        protocol,
        presharedKey,
        username,
        password,
        useEncryption = true,
        useCompression = false
      } = req.body;

      // Validate input
      if (!connectionName || !serverAddress || !username || !password) {
        return res.status(400).json({
          success: false,
          error: 'Missing required fields: connectionName, serverAddress, username, password'
        });
      }

      console.log(`Creating VPN connection: ${connectionName}`);

      // Build vpncmd command based on protocol
      let vpncmdCommand = '';

      if (protocol === 'l2tpipsec') {
        // L2TP/IPSec command
        vpncmdCommand = this.buildL2TPCommand(
          connectionName,
          serverAddress,
          serverPort,
          presharedKey,
          username,
          password
        );
      } else if (protocol === 'openvpn') {
        vpncmdCommand = this.buildOpenVpnCommand(
          connectionName,
          serverAddress,
          serverPort,
          username,
          password
        );
      } else {
        return res.status(400).json({
          success: false,
          error: `Protocol not supported: ${protocol}`
        });
      }

      // Execute vpncmd
      const result = await this.executeVpnCommand(vpncmdCommand);

      // Check if command succeeded
      if (result.success) {
        return res.status(200).json({
          success: true,
          message: 'VPN connection created successfully',
          connectionName: connectionName,
          status: 'connected'
        });
      } else {
        return res.status(400).json({
          success: false,
          error: result.error || 'Failed to create VPN connection'
        });
      }
    } catch (error) {
      console.error('Error creating VPN connection:', error);
      return res.status(500).json({
        success: false,
        error: error.message
      });
    }
  }

  /**
   * Disconnect from VPN
   * POST /api/softether/disconnect
   */
  async disconnectConnection(req, res) {
    try {
      const { connectionName } = req.body;

      if (!connectionName) {
        return res.status(400).json({
          success: false,
          error: 'connectionName is required'
        });
      }

      console.log(`Disconnecting VPN: ${connectionName}`);

      // Build disconnect command
      const vpncmdCommand = `
        ${this.vpncmdPath} /tools ${this.vpnServerAddress} /password:${this.vpnPassword} /clientdisconnect "${connectionName}"
      `.trim();

      const result = await this.executeVpnCommand(vpncmdCommand);

      if (result.success) {
        return res.status(200).json({
          success: true,
          message: 'VPN disconnected successfully',
          connectionName: connectionName
        });
      } else {
        return res.status(400).json({
          success: false,
          error: result.error
        });
      }
    } catch (error) {
      console.error('Error disconnecting VPN:', error);
      return res.status(500).json({
        success: false,
        error: error.message
      });
    }
  }

  /**
   * Get connection status
   * GET /api/softether/status/:connectionName
   */
  async getConnectionStatus(req, res) {
    try {
      const { connectionName } = req.params;

      console.log(`Getting status for: ${connectionName}`);

      // Build status command
      const vpncmdCommand = `
        ${this.vpncmdPath} /tools ${this.vpnServerAddress} /password:${this.vpnPassword} /sessionlist
      `.trim();

      const result = await this.executeVpnCommand(vpncmdCommand);

      if (result.success && result.output.includes(connectionName)) {
        return res.status(200).json({
          success: true,
          connectionName: connectionName,
          status: 'connected',
          output: result.output
        });
      } else {
        return res.status(200).json({
          success: true,
          connectionName: connectionName,
          status: 'disconnected'
        });
      }
    } catch (error) {
      console.error('Error getting VPN status:', error);
      return res.status(500).json({
        success: false,
        error: error.message
      });
    }
  }

  /**
   * List all VPN connections
   * GET /api/softether/list
   */
  async listConnections(req, res) {
    try {
      console.log('Listing all VPN connections');

      const vpncmdCommand = `
        ${this.vpncmdPath} /tools ${this.vpnServerAddress} /password:${this.vpnPassword} /sessionlist
      `.trim();

      const result = await this.executeVpnCommand(vpncmdCommand);

      return res.status(200).json({
        success: true,
        connections: result.output,
        message: 'VPN connections listed successfully'
      });
    } catch (error) {
      console.error('Error listing VPN connections:', error);
      return res.status(500).json({
        success: false,
        error: error.message
      });
    }
  }

  /**
   * Build L2TP/IPSec vpncmd command
   */
  buildL2TPCommand(name, address, port, presharedKey, username, password) {
    return `
      ${this.vpncmdPath} /tools ${this.vpnServerAddress} /password:${this.vpnPassword} /clientconnect target="${address}" port="${port}" protocol=l2tp encryptionLevel=standard auth=presharedsecret presharedsecretvalue="${presharedKey}" accountname="${username}" password="${password}" devicename="${name}"
    `.trim();
  }

  /**
   * Build OpenVPN vpncmd command
   */
  buildOpenVpnCommand(name, address, port, username, password) {
    return `
      ${this.vpncmdPath} /tools ${this.vpnServerAddress} /password:${this.vpnPassword} /clientconnect target="${address}" port="${port}" protocol=openvpn accountname="${username}" password="${password}" devicename="${name}"
    `.trim();
  }

  /**
   * Execute vpn command and return result
   */
  async executeVpnCommand(command) {
    try {
      console.log('Executing vpncmd:', command);

      const { stdout, stderr } = await exec(command);

      // Check for error indicators in output
      if (stderr && stderr.toLowerCase().includes('error')) {
        return {
          success: false,
          error: stderr,
          output: stdout
        };
      }

      return {
        success: true,
        output: stdout,
        error: null
      };
    } catch (error) {
      console.error('vpncmd execution error:', error);
      return {
        success: false,
        error: error.message || error.stderr,
        output: error.stdout
      };
    }
  }
}

module.exports = new VpnController();
```

#### 7. Create .env file

```bash
# .env
PORT=8000
VPN_SERVER_ADDRESS=localhost:5555
VPN_SERVER_PASSWORD=admin
VPNCMD_PATH=/usr/bin/vpncmd
LOG_LEVEL=debug
```

#### 8. Run the Server

```bash
cd ~/softether-api
npm start

# Or for development with auto-restart:
npm install -g nodemon
nodemon app.js
```

### Phase 2: Update Flutter App SoftEtherPort

Once your Node.js API is running, update the `softether_port.dart` file:

```dart
// Add to imports
import 'package:http/http.dart' as http;

// Update connectSoftEther method
Future<bool> connectSoftEther(SoftEtherConfig config) async {
  try {
    debugPrint('[SoftEtherPort] Connecting to SoftEther VPN: ${config.connectionName}');

    if (!_isInitialized) {
      await initialize();
    }

    if (_isConnected) {
      await disconnect();
      await Future.delayed(const Duration(seconds: 1));
    }

    _currentConfig = config;
    _stageController.add(VPNStage.connecting);

    // Call EC2 API
    final response = await http.post(
      Uri.parse('https://100.28.211.202:8000/api/softether/connect'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'connectionName': config.connectionName,
        'serverAddress': config.serverAddress,
        'serverPort': config.serverPort,
        'protocol': config.protocol.toStringValue(),
        'presharedKey': config.presharedKey,
        'username': config.username,
        'password': config.password,
        'useEncryption': config.useEncryption,
        'useCompression': config.useCompression,
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['success'] == true) {
        _isConnected = true;
        _stageController.add(VPNStage.connected);
        _startHealthCheck();
        debugPrint('[SoftEtherPort] Connected successfully');
        return true;
      }
    }

    debugPrint('[SoftEtherPort] Connection failed: ${response.body}');
    _stageController.add(VPNStage.error);
    return false;
  } catch (e, stackTrace) {
    debugPrint('[SoftEtherPort] Error connecting: $e');
    debugPrint('[SoftEtherPort] Stack trace: $stackTrace');
    _isConnected = false;
    _stageController.add(VPNStage.error);
    return false;
  }
}
```

### Phase 3: Security Considerations

1. **HTTPS**: Use SSL certificates (Let's Encrypt is free)
```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot certonly --standalone -d your-ec2-ip-or-domain.com
```

2. **API Authentication**: Add JWT or API key validation
```dart
headers: {
  'Content-Type': 'application/json',
  'Authorization': 'Bearer YOUR_API_KEY',
},
```

3. **Firewall Rules**: Only allow Flutter app to call API
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp \
  --port 8000 \
  --cidr YOUR_APP_IP/32
```

### Phase 4: Testing

#### Test API Endpoint
```bash
curl -X POST https://100.28.211.202:8000/api/softether/connect \
  -H "Content-Type: application/json" \
  -d '{
    "connectionName": "Test VPN",
    "serverAddress": "100.28.211.202",
    "serverPort": 5555,
    "protocol": "l2tpipsec",
    "presharedKey": "admin",
    "username": "testuser",
    "password": "testpass"
  }'
```

#### Health Check
```bash
curl https://100.28.211.202:8000/health
```

### Phase 5: Monitoring & Logging

Add logging to Node.js API:
```javascript
const winston = require('winston');

const logger = winston.createLogger({
  level: 'info',
  format: winston.format.json(),
  transports: [
    new winston.transports.File({ filename: 'vpn-api.log' })
  ]
});

logger.info('VPN connection created:', { connectionName });
```

## Checklist

- [ ] Node.js installed on EC2
- [ ] Node.js API code created
- [ ] vpncmd paths verified
- [ ] API tested with curl
- [ ] Flutter app updated with HTTP calls
- [ ] SSL certificate configured (optional but recommended)
- [ ] API authentication implemented
- [ ] Logging configured
- [ ] Security groups configured
- [ ] End-to-end tested from Flutter app

## Troubleshooting

**vpncmd not found**: Check path
```bash
which vpncmd
# If not found, install SoftEther VPN Server
```

**API fails to start**: Check port 8000 availability
```bash
lsof -i :8000
```

**Connection fails in Flutter**: Check logs
```bash
# On EC2
tail -f vpn-api.log

# In Android Logcat
flutter logs | grep SoftEtherPort
```

**CORS errors**: Verify cors() middleware in app.js

---

This implementation provides a complete bridge between your Flutter app and vpncmd on EC2. Test thoroughly before deploying to production!
