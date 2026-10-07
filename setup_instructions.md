# Video Wall Control Panel Setup Guide

## Overview
This solution provides a tablet-friendly web interface to control your 2x2 Samsung Business TV video wall (model LH55BECHLGFXGO). It uses Samsung's official MDC (Multiple Display Control) protocol for reliable communication and includes both individual TV controls and global management features.

## Prerequisites

### Hardware Requirements
- 4x Samsung Business TVs (LH55BECHLGFXGO) arranged in 2x2 configuration
- Network switch/router with all TVs connected via Ethernet
- Server/computer to run the Python backend (can be a Raspberry Pi 4+)
- Tablet or device with web browser for control interface

### Software Requirements
- Python 3.8 or higher
- Network access to all TVs
- Modern web browser on your tablet (Chrome, Safari, Firefox, Edge)

## Installation

### 1. Python Dependencies

Create a `requirements.txt` file:

```txt
flask==2.3.3
flask-cors==4.0.0
python-samsung-mdc>=1.0.0
asyncio
```

Install dependencies:
```bash
pip install -r requirements.txt
```

**Important**: The `python-samsung-mdc` library is required for proper communication with Samsung Business TVs.

### 2. TV Network Configuration

#### Configure Display IDs on TVs
Each TV needs a unique Display ID for MDC communication:

1. On each TV, go to: **Settings → General → System Manager → Device Options**
2. Set **Display ID** to unique values:
   - TV 1 (Top Left): Display ID = 1
   - TV 2 (Top Right): Display ID = 2  
   - TV 3 (Bottom Left): Display ID = 3
   - TV 4 (Bottom Right): Display ID = 4

#### Enable MDC Protocol
1. Go to: **Settings → General → External Device Manager**
2. Enable **Device Connect Manager**
3. Set **Access Notification** to **First Time Only**
4. Enable **Network Remote Control**

#### Network Settings
1. Go to: **Settings → General → Network**
2. Configure static IP addresses for each TV:
   - TV 1: 192.168.1.101
   - TV 2: 192.168.1.102
   - TV 3: 192.168.1.103  
   - TV 4: 192.168.1.104
3. Ensure all TVs are on the same subnet as your control server

### 3. Configure the Backend

Edit the `video_wall_backend.py` file and update the TV configurations:

```python
self.tvs = {
    1: SamsungTVController(TVConfig(1, "Top Left", "192.168.1.101", display_id=1, position="top-left")),
    2: SamsungTVController(TVConfig(2, "Top Right", "192.168.1.102", display_id=2, position="top-right")),
    3: SamsungTVController(TVConfig(3, "Bottom Left", "192.168.1.103", display_id=3, position="bottom-left")),
    4: SamsungTVController(TVConfig(4, "Bottom Right", "192.168.1.104", display_id=4, position="bottom-right"))
}
```

Replace the IP addresses with your actual TV IPs and ensure Display IDs match your TV settings.

### 4. Running the System

#### Start the Backend Server
```bash
python video_wall_backend.py
```

The server will start on `http://localhost:5000` and display connection status for each TV.

#### Access the Control Panel
1. Save the HTML file as `video_wall_control.html`
2. If your server is on a different device, update the API endpoint in the HTML file:
   ```javascript
   const API_BASE = 'http://YOUR_SERVER_IP:5000/api';
   ```
3. Open the HTML file in your tablet's web browser

## Samsung MDC Protocol Details

### Communication Method
- **Protocol**: Samsung MDC (Multiple Display Control) over TCP/IP
- **Port**: 1515 (default)
- **Format**: Binary protocol with structured commands
- **Authentication**: Display ID based access control

### Supported Commands
The system supports all major MDC commands:
- Power control (on/off/reboot)
- Volume control (0-100, mute/unmute)
- Input source selection (HDMI1-4, USB, Network, MagicInfo)
- Video wall configuration (2x2 grid setup)
- Display settings (brightness, contrast, etc.)
- Network configuration
- Content management

### Video Wall Configuration
The system automatically configures a 2x2 video wall layout:
- **Model**: "2,2" (2 columns × 2 rows)
- **Serial Numbers**: 1=Top-Left, 2=Top-Right, 3=Bottom-Left, 4=Bottom-Right
- **Mode**: Supports both NATURAL (maintain aspect ratio) and FULL (stretch to fill) modes

## Troubleshooting

### TVs Not Responding
1. **Check Network Connectivity**
   ```bash
   ping 192.168.1.101  # Test each TV IP
   ```

2. **Verify MDC Port Access**
   ```bash
   telnet 192.168.1.101 1515
   ```

3. **Test with Samsung MDC CLI**
   ```bash
   samsung-mdc 1@192.168.1.101 status
   ```

4. **Check Display ID Configuration**
   - Ensure each TV has a unique Display ID (1-4)
   - Verify Display IDs match the backend configuration

### Connection Issues
1. **Firewall Settings**
   - Ensure port 1515 is open on all TVs
   - Check network firewall rules

2. **TV Network Settings**
   - Verify static IP configuration
   - Ensure Network Remote Control is enabled
   - Check that Device Connect Manager is enabled

3. **Backend Logs**
   - Check console output for connection errors
   - Verify Samsung MDC library installation

### Common Error Messages

**"Samsung MDC library not available"**
```bash
pip install python-samsung-mdc
```

**"Could not connect to TV X"**
- Check TV IP address and network connectivity
- Verify Display ID settings on TV
- Ensure MDC is enabled in TV settings

**"Command failed" or "NAK errors"**
- Try powering TV on first
- Switch to HDMI1 input before sending commands
- Ensure TV is fully booted (wait 30 seconds after power on)

### Testing Individual Components

**Test MDC Connection:**
```bash
python3 -c "
import asyncio
from samsung_mdc import MDC

async def test():
    async with MDC('192.168.1.101', timeout=5) as mdc:
        status = await mdc.status(1)
        print(f'TV Status: {status}')

asyncio.run(test())
"
```

**Test Backend API:**
```bash
curl http://localhost:5000/health
curl -X POST http://localhost:5000/api/tv/1/power
```

## Advanced Configuration

### Custom Content Integration

#### MagicInfo Setup
1. Install Samsung MagicInfo Server on network
2. Configure server IP in control panel
3. Create content schedules and playlists
4. Use control panel to switch TVs to MagicInfo input

#### Web Content Delivery
1. Set up internal web server for custom content
2. Create HTML/CSS/JS content for displays
3. Use URL Launcher input to display web content
4. Configure content URLs in preset management

#### Streaming Integration
- **RTMP Streams**: Use external RTMP to HDMI decoder
- **HTTP Streams**: Direct URL playback via network input
- **Local Media**: USB playback or network media server

### Video Wall Layouts

The system supports various video wall configurations:

**2x2 Grid (Current Setup):**
```
[1] [2]
[3] [4]
```

**Custom Layouts** (modify backend code):
- 1x4 Horizontal strip
- 4x1 Vertical strip  
- 3x3 Grid (requires 9 displays)

### Automation and Scheduling

**Timer Functions:**
```python
# Power on at 8 AM, off at 6 PM weekdays
samsung-mdc 1@192.168.1.101 timer_15 1 08:00 true 18:00 true everyday true mon,tue,wed,thu,fri everyday true mon,tue,wed,thu,fri 50 hdmi1 dont_apply_both
```

**Scheduled Content:**
- Use TV's built-in timer functions
- Integrate with cron jobs on server
- MagicInfo scheduling for automated content

## Production Deployment

### Using systemd Service
Create `/etc/systemd/system/video-wall.service`:
```ini
[Unit]
Description=Samsung Video Wall Control Service
After=network.target

[Service]
Type=simple
User=videowall
WorkingDirectory=/opt/video-wall-control
ExecStart=/usr/bin/python3 video_wall_backend.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl enable video-wall.service
sudo systemctl start video-wall.service
```

### Nginx Reverse Proxy
```nginx
server {
    listen 80;
    server_name video-wall.company.com;
    
    location / {
        try_files $uri $uri/ /video_wall_control.html;
    }
    
    location /api/ {
        proxy_pass http://localhost:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### SSL/HTTPS Setup
```bash
sudo certbot --nginx -d video-wall.company.com
```

## Performance Optimization

### Network Optimization
- Use Gigabit Ethernet for all connections
- Configure Quality of Service (QoS) for MDC traffic
- Use managed switches for better control

### Backend Optimization  
- Implement connection pooling for MDC connections
- Add caching for TV status queries
- Use async operations for bulk commands

### Frontend Optimization
- Enable browser caching for static assets
- Use WebSocket connections for real-time updates
- Implement offline fallback functionality

## Monitoring and Maintenance

### Health Monitoring
```bash
# Check all TV status
curl http://localhost:5000/health

# Monitor backend logs
journalctl -u video-wall.service -f
```

### Regular Maintenance
- Weekly TV firmware updates
- Monthly network connectivity tests  
- Quarterly configuration backups
- Annual hardware inspection

### Backup and Recovery
```bash
# Backup TV configurations
samsung-mdc 1@192.168.1.101:1515 status > tv1_backup.txt

# Export backend configuration
curl http://localhost:5000/api/config > config_backup.json
```

## Support Resources

### Samsung Business Support
- **Documentation**: https://displaysolutions.samsung.com/
- **MDC Protocol**: Contact Samsung Business support for latest protocol documentation
- **Firmware Updates**: Samsung Business portal

### Third-Party Tools
- **Samsung MDC Unified**: Official Windows GUI tool for testing
- **MDC Protocol Analyzer**: For debugging communication issues
- **Network Monitoring**: Use tools like Wireshark to analyze MDC traffic

### Community Resources
- **GitHub Projects**: Search for "samsung-mdc" implementations
- **Professional AV Forums**: AVS Forum, Professional Display community
- **Samsung Developer Portal**: For advanced API integrations

This setup provides enterprise-grade control of your Samsung Business TV video wall with reliable MDC protocol communication and comprehensive management features.