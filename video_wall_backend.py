#!/usr/bin/env python3
"""
Video Wall Control Backend for Samsung Business TVs
Model: LH55BECHLGFXGO (BEC-H Series Crystal UHD 4K Pro TV)
Software: T-KSU2ECAKUC-0080-2024.2

This Flask application provides API endpoints to control a 2x2 video wall
of Samsung Business displays using Samsung's MDC (Multiple Display Control) protocol.

Installation requirements:
pip install python-samsung-mdc flask flask-cors
"""

from flask import Flask, request, jsonify
from flask_cors import CORS
import asyncio
import logging
from typing import Dict, List, Optional
from dataclasses import dataclass
from threading import Lock
import json
import time

# Import Samsung MDC library
try:
    from samsung_mdc import MDC
    MDC_AVAILABLE = True
except ImportError:
    print("Warning: python-samsung-mdc not installed. Install with: pip install python-samsung-mdc")
    MDC_AVAILABLE = False

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)  # Enable CORS for frontend

@dataclass
class TVConfig:
    """Configuration for each TV in the video wall"""
    id: int
    name: str
    ip_address: str
    display_id: int  # Samsung MDC Display ID (0-255)
    port: int = 1515  # Samsung MDC default port
    position: str = ""  # "top-left", "top-right", "bottom-left", "bottom-right"

class SamsungTVController:
    """Controller for Samsung Business TV using MDC Protocol"""
    
    def __init__(self, tv_config: TVConfig):
        self.config = tv_config
        self.is_connected = False
        self.current_volume = 50
        self.current_input = "HDMI1"
        self.is_powered_on = True
        self.is_muted = False
        self.lock = Lock()
        self.mdc = None
        
    async def connect(self) -> bool:
        """Establish MDC connection to the TV"""
        if not MDC_AVAILABLE:
            logger.error("Samsung MDC library not available")
            return False
            
        try:
            self.mdc = MDC(self.config.ip_address, port=self.config.port, timeout=5)
            
            # Test connection by getting status
            status = await self.mdc.status(self.config.display_id)
            if status:
                self.is_connected = True
                # Update current state from TV
                self.is_powered_on = (status[0] == MDC.power.POWER_STATE.ON)
                if len(status) > 1 and status[1] != 255:  # 255 means no audio support
                    self.current_volume = status[1]
                if len(status) > 2:
                    self.is_muted = (status[2] == MDC.mute.MUTE_STATE.ON)
                if len(status) > 3:
                    self.current_input = self._map_input_from_mdc(status[3])
                
                logger.info(f"Connected to TV {self.config.id} ({self.config.name}) via MDC")
                return True
            else:
                logger.warning(f"Could not get status from TV {self.config.id}")
                return False
                
        except Exception as e:
            logger.error(f"MDC connection error for TV {self.config.id}: {e}")
            return False
    
    async def disconnect(self):
        """Close MDC connection"""
        if self.mdc:
            await self.mdc.close()
            self.mdc = None
            self.is_connected = False
    
    def _map_input_to_mdc(self, input_name: str):
        """Map frontend input names to MDC input states"""
        input_map = {
            'hdmi1': MDC.input_source.INPUT_SOURCE_STATE.HDMI1,
            'hdmi2': MDC.input_source.INPUT_SOURCE_STATE.HDMI2,
            'hdmi3': MDC.input_source.INPUT_SOURCE_STATE.HDMI3,
            'hdmi4': MDC.input_source.INPUT_SOURCE_STATE.HDMI4,
            'usb': MDC.input_source.INPUT_SOURCE_STATE.INTERNAL_USB,
            'network': MDC.input_source.INPUT_SOURCE_STATE.URL_LAUNCHER,
            'magicinfo': MDC.input_source.INPUT_SOURCE_STATE.MAGIC_INFO,
            'dvi': MDC.input_source.INPUT_SOURCE_STATE.DVI,
            'pc': MDC.input_source.INPUT_SOURCE_STATE.PC
        }
        return input_map.get(input_name.lower(), MDC.input_source.INPUT_SOURCE_STATE.HDMI1)
    
    def _map_input_from_mdc(self, mdc_input):
        """Map MDC input states back to frontend names"""
        reverse_map = {
            MDC.input_source.INPUT_SOURCE_STATE.HDMI1: 'hdmi1',
            MDC.input_source.INPUT_SOURCE_STATE.HDMI2: 'hdmi2',
            MDC.input_source.INPUT_SOURCE_STATE.HDMI3: 'hdmi3',
            MDC.input_source.INPUT_SOURCE_STATE.HDMI4: 'hdmi4',
            MDC.input_source.INPUT_SOURCE_STATE.INTERNAL_USB: 'usb',
            MDC.input_source.INPUT_SOURCE_STATE.URL_LAUNCHER: 'network',
            MDC.input_source.INPUT_SOURCE_STATE.MAGIC_INFO: 'magicinfo',
            MDC.input_source.INPUT_SOURCE_STATE.DVI: 'dvi',
            MDC.input_source.INPUT_SOURCE_STATE.PC: 'pc'
        }
        return reverse_map.get(mdc_input, 'hdmi1')
    
    async def send_command(self, command: str, params: Dict = None) -> Dict:
        """Send command to the TV using MDC protocol"""
        if not self.mdc or not self.is_connected:
            if not await self.connect():
                return {'success': False, 'error': 'Not connected to TV'}
        
        with self.lock:
            try:
                display_id = self.config.display_id
                
                if command == 'power_toggle':
                    current_status = await self.mdc.status(display_id)
                    if current_status and current_status[0] == MDC.power.POWER_STATE.ON:
                        await self.mdc.power(display_id, [MDC.power.POWER_STATE.OFF])
                        self.is_powered_on = False
                    else:
                        await self.mdc.power(display_id, [MDC.power.POWER_STATE.ON])
                        self.is_powered_on = True
                    return {'success': True, 'power_state': 'on' if self.is_powered_on else 'off'}
                
                elif command == 'power_on':
                    await self.mdc.power(display_id, [MDC.power.POWER_STATE.ON])
                    self.is_powered_on = True
                    return {'success': True, 'power_state': 'on'}
                
                elif command == 'power_off':
                    await self.mdc.power(display_id, [MDC.power.POWER_STATE.OFF])
                    self.is_powered_on = False
                    return {'success': True, 'power_state': 'off'}
                
                elif command == 'set_volume' and params and 'volume' in params:
                    volume = max(0, min(100, int(params['volume'])))
                    await self.mdc.volume(display_id, [volume])
                    self.current_volume = volume
                    return {'success': True, 'volume': volume}
                
                elif command == 'mute_toggle':
                    current_mute = MDC.mute.MUTE_STATE.OFF if self.is_muted else MDC.mute.MUTE_STATE.ON
                    await self.mdc.mute(display_id, [current_mute])
                    self.is_muted = not self.is_muted
                    return {'success': True, 'muted': self.is_muted}
                
                elif command == 'set_input' and params and 'input' in params:
                    input_source = self._map_input_to_mdc(params['input'])
                    await self.mdc.input_source(display_id, [input_source])
                    self.current_input = params['input']
                    return {'success': True, 'input': params['input']}
                
                elif command == 'get_status':
                    status = await self.mdc.status(display_id)
                    if status:
                        self.is_powered_on = (status[0] == MDC.power.POWER_STATE.ON)
                        if len(status) > 1 and status[1] != 255:
                            self.current_volume = status[1]
                        if len(status) > 2:
                            self.is_muted = (status[2] == MDC.mute.MUTE_STATE.ON)
                        if len(status) > 3:
                            self.current_input = self._map_input_from_mdc(status[3])
                        
                        return {
                            'success': True,
                            'power_state': 'on' if self.is_powered_on else 'off',
                            'volume': self.current_volume,
                            'muted': self.is_muted,
                            'input': self.current_input
                        }
                    else:
                        return {'success': False, 'error': 'Could not get status'}
                
                # Video wall specific commands
                elif command == 'video_wall_setup' and params:
                    # Enable video wall mode
                    await self.mdc.video_wall_state(display_id, [MDC.video_wall_state.VIDEO_WALL_STATE.ON])
                    
                    # Set video wall model (e.g., "2,2" for 2x2 grid)
                    model = params.get('model', '2,2')
                    serial = params.get('serial', self.config.id)  # Position in wall
                    await self.mdc.video_wall_model(display_id, [model, serial])
                    
                    return {'success': True, 'video_wall_enabled': True}
                
                elif command == 'video_wall_disable':
                    await self.mdc.video_wall_state(display_id, [MDC.video_wall_state.VIDEO_WALL_STATE.OFF])
                    return {'success': True, 'video_wall_enabled': False}
                
                else:
                    return {'success': False, 'error': f'Unknown command: {command}'}
                    
            except Exception as e:
                logger.error(f"MDC command error for TV {self.config.id}: {e}")
                # Try to reconnect on next command
                await self.disconnect()
                return {'success': False, 'error': str(e)}

class VideoWallManager:
    """Manages the entire 2x2 video wall using Samsung MDC Protocol"""
    
    def __init__(self):
        # Configure your TV IP addresses and display IDs here
        # Display IDs should be unique for each TV and configured in TV settings
        self.tvs = {
            1: SamsungTVController(TVConfig(1, "Top Left", "192.168.1.101", display_id=1, position="top-left")),
            2: SamsungTVController(TVConfig(2, "Top Right", "192.168.1.102", display_id=2, position="top-right")),
            3: SamsungTVController(TVConfig(3, "Bottom Left", "192.168.1.103", display_id=3, position="bottom-left")),
            4: SamsungTVController(TVConfig(4, "Bottom Right", "192.168.1.104", display_id=4, position="bottom-right"))
        }
        self.magicinfo_server = None
        self.current_preset = None
        self.video_wall_enabled = False
        
    async def initialize(self):
        """Initialize all TV connections and configure video wall"""
        logger.info("Initializing video wall connections...")
        connection_results = []
        
        for tv_id, controller in self.tvs.items():
            success = await controller.connect()
            connection_results.append((tv_id, success))
            if success:
                logger.info(f"TV {tv_id} ({controller.config.name}) connected successfully")
            else:
                logger.warning(f"TV {tv_id} ({controller.config.name}) connection failed")
        
        # If all TVs are connected, set up video wall configuration
        if all(result[1] for result in connection_results):
            await self.setup_video_wall()
        
        return connection_results
    
    async def setup_video_wall(self):
        """Configure the 2x2 video wall layout"""
        try:
            logger.info("Setting up 2x2 video wall configuration...")
            
            # Video wall position mapping for 2x2 grid
            # Serial numbers go left-to-right, top-to-bottom
            wall_positions = {
                1: 1,  # Top Left
                2: 2,  # Top Right  
                3: 3,  # Bottom Left
                4: 4   # Bottom Right
            }
            
            for tv_id, controller in self.tvs.items():
                if controller.is_connected:
                    result = await controller.send_command('video_wall_setup', {
                        'model': '2,2',  # 2x2 grid
                        'serial': wall_positions[tv_id]
                    })
                    if result.get('success'):
                        logger.info(f"Video wall configured for TV {tv_id}")
                    else:
                        logger.error(f"Failed to configure video wall for TV {tv_id}: {result.get('error')}")
            
            self.video_wall_enabled = True
            logger.info("Video wall setup complete")
            
        except Exception as e:
            logger.error(f"Video wall setup error: {e}")
    
    async def disable_video_wall(self):
        """Disable video wall mode on all TVs"""
        try:
            for tv_id, controller in self.tvs.items():
                if controller.is_connected:
                    await controller.send_command('video_wall_disable')
            self.video_wall_enabled = False
            logger.info("Video wall disabled")
        except Exception as e:
            logger.error(f"Error disabling video wall: {e}")
    
    def get_tv(self, tv_id: int) -> Optional[SamsungTVController]:
        """Get TV controller by ID"""
        return self.tvs.get(tv_id)
    
    async def cleanup(self):
        """Close all TV connections"""
        for tv_id, controller in self.tvs.items():
            await controller.disconnect()

# Global video wall manager
video_wall = VideoWallManager()

# Helper function to run async functions in Flask routes
def run_async(coro):
    """Run async function in Flask route"""
    try:
        loop = asyncio.get_event_loop()
    except RuntimeError:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
    
    return loop.run_until_complete(coro)

# API Routes
@app.route('/api/tv/<int:tv_id>/power', methods=['POST'])
def toggle_power(tv_id):
    """Toggle power for specific TV"""
    tv = video_wall.get_tv(tv_id)
    if not tv:
        return jsonify({'error': 'TV not found'}), 404
    
    result = run_async(tv.send_command('power_toggle'))
    
    if result.get('success'):
        return jsonify({
            'status': result.get('power_state', 'unknown'),
            'success': True
        })
    else:
        return jsonify({'error': result.get('error', 'Command failed')}), 500

@app.route('/api/tv/<int:tv_id>/volume', methods=['POST'])
def set_volume(tv_id):
    """Set volume for specific TV"""
    tv = video_wall.get_tv(tv_id)
    if not tv:
        return jsonify({'error': 'TV not found'}), 404
    
    data = request.get_json()
    volume = data.get('volume', 50)
    
    result = run_async(tv.send_command('set_volume', {'volume': volume}))
    
    if result.get('success'):
        return jsonify({'volume': volume, 'success': True})
    else:
        return jsonify({'error': result.get('error', 'Command failed')}), 500

@app.route('/api/tv/<int:tv_id>/mute', methods=['POST'])
def toggle_mute(tv_id):
    """Toggle mute for specific TV"""
    tv = video_wall.get_tv(tv_id)
    if not tv:
        return jsonify({'error': 'TV not found'}), 404
    
    result = run_async(tv.send_command('mute_toggle'))
    
    if result.get('success'):
        return jsonify({'muted': result.get('muted', False), 'success': True})
    else:
        return jsonify({'error': result.get('error', 'Command failed')}), 500

@app.route('/api/tv/<int:tv_id>/input', methods=['POST'])
def set_input(tv_id):
    """Set input source for specific TV"""
    tv = video_wall.get_tv(tv_id)
    if not tv:
        return jsonify({'error': 'TV not found'}), 404
    
    data = request.get_json()
    input_source = data.get('input', 'hdmi1')
    
    result = run_async(tv.send_command('set_input', {'input': input_source}))
    
    if result.get('success'):
        return jsonify({'input': input_source, 'success': True})
    else:
        return jsonify({'error': result.get('error', 'Command failed')}), 500

@app.route('/api/tv/<int:tv_id>/status', methods=['GET'])
def get_tv_status(tv_id):
    """Get status of specific TV"""
    tv = video_wall.get_tv(tv_id)
    if not tv:
        return jsonify({'error': 'TV not found'}), 404
    
    # Try to get real-time status from TV
    status_result = run_async(tv.send_command('get_status'))
    
    if status_result.get('success'):
        return jsonify({
            'id': tv_id,
            'status': status_result.get('power_state', 'unknown'),
            'volume': status_result.get('volume', tv.current_volume),
            'input': status_result.get('input', tv.current_input),
            'muted': status_result.get('muted', tv.is_muted),
            'connected': tv.is_connected
        })
    else:
        # Return cached status if real-time query fails
        return jsonify({
            'id': tv_id,
            'status': 'on' if tv.is_powered_on else 'off',
            'volume': tv.current_volume,
            'input': tv.current_input,
            'muted': tv.is_muted,
            'connected': tv.is_connected
        })

@app.route('/api/videowall/reset', methods=['POST'])
def reset_video_wall():
    """Reset entire video wall"""
    try:
        # Disable video wall mode first
        run_async(video_wall.disable_video_wall())
        
        # Turn off all TVs
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                run_async(tv.send_command('power_off'))
                time.sleep(1)
        
        time.sleep(3)  # Wait for shutdown
        
        # Turn on all TVs
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                run_async(tv.send_command('power_on'))
                time.sleep(1)
        
        time.sleep(5)  # Wait for boot
        
        # Re-enable video wall
        run_async(video_wall.setup_video_wall())
        
        return jsonify({'success': True, 'message': 'Video wall reset complete'})
    except Exception as e:
        logger.error(f"Video wall reset error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/videowall/setup', methods=['POST'])
def setup_video_wall_route():
    """Enable video wall mode"""
    try:
        run_async(video_wall.setup_video_wall())
        return jsonify({'success': True, 'message': 'Video wall enabled'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/videowall/disable', methods=['POST'])
def disable_video_wall_route():
    """Disable video wall mode"""
    try:
        run_async(video_wall.disable_video_wall())
        return jsonify({'success': True, 'message': 'Video wall disabled'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/content/preset', methods=['POST'])
def load_preset():
    """Load content preset"""
    data = request.get_json()
    preset_name = data.get('preset')
    
    # Preset configurations for Samsung Business TVs
    presets = {
        'welcome': {
            'input': 'network',
            'url': 'http://your-server/welcome.html'
        },
        'digital-signage': {
            'input': 'magicinfo',
            'channel': 1
        },
        'news': {
            'input': 'network',
            'url': 'http://your-server/news-feed.html'
        },
        'weather': {
            'input': 'network', 
            'url': 'http://your-server/weather.html'
        },
        'corporate': {
            'input': 'network',
            'url': 'http://your-server/corporate-info.html'
        },
        'blank': {
            'input': 'hdmi1',
            'action': 'screen_mute'
        }
    }
    
    if preset_name not in presets:
        return jsonify({'error': 'Preset not found'}), 404
    
    preset_config = presets[preset_name]
    
    try:
        # Apply preset to all TVs
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                # Set input source
                if 'input' in preset_config:
                    run_async(tv.send_command('set_input', {'input': preset_config['input']}))
                
                # Special actions for specific presets
                if preset_name == 'blank':
                    # Use screen mute for blank screen
                    try:
                        if hasattr(tv.mdc, 'screen_mute'):
                            run_async(tv.mdc.screen_mute(tv.config.display_id, ['ON']))
                    except:
                        pass  # Fallback handled by input change
                
                time.sleep(0.5)  # Small delay between TV commands
        
        video_wall.current_preset = preset_name
        return jsonify({'success': True, 'preset': preset_name})
        
    except Exception as e:
        logger.error(f"Error loading preset {preset_name}: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/magicinfo/connect', methods=['POST'])
def connect_magicinfo():
    """Connect to MagicInfo server"""
    data = request.get_json()
    server_ip = data.get('server')
    
    if not server_ip:
        return jsonify({'error': 'Server IP required'}), 400
    
    try:
        video_wall.magicinfo_server = server_ip
        
        # Configure MagicInfo server on all TVs
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected and tv.mdc:
                try:
                    # Set MagicInfo server URL
                    magicinfo_url = f"http://{server_ip}:7001"
                    run_async(tv.mdc.magicinfo_server(tv.config.display_id, [magicinfo_url]))
                    logger.info(f"MagicInfo server configured on TV {tv_id}")
                except Exception as e:
                    logger.warning(f"Could not configure MagicInfo on TV {tv_id}: {e}")
        
        return jsonify({'success': True, 'server': server_ip})
        
    except Exception as e:
        logger.error(f"MagicInfo connection error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/magicinfo/refresh', methods=['POST'])
def refresh_magicinfo():
    """Refresh MagicInfo content"""
    try:
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                # Switch to MagicInfo input to refresh content
                run_async(tv.send_command('set_input', {'input': 'magicinfo'}))
                time.sleep(0.5)
        
        return jsonify({'success': True, 'message': 'MagicInfo content refreshed'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/streaming/start', methods=['POST'])
def start_streaming():
    """Start streaming to video wall"""
    data = request.get_json()
    stream_url = data.get('url')
    
    if not stream_url:
        return jsonify({'error': 'Stream URL required'}), 400
    
    try:
        # Switch all TVs to appropriate input for streaming
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                # For network streams, use URL launcher or network input
                if stream_url.startswith(('http://', 'https://')):
                    run_async(tv.send_command('set_input', {'input': 'network'}))
                    
                    # If TV supports URL launcher, set the URL
                    if tv.mdc and hasattr(tv.mdc, 'launcher_url_address'):
                        try:
                            run_async(tv.mdc.launcher_url_address(tv.config.display_id, [stream_url]))
                        except Exception as e:
                            logger.warning(f"Could not set URL on TV {tv_id}: {e}")
                
                # For RTMP or other streams, use HDMI input with external decoder
                elif stream_url.startswith('rtmp://'):
                    run_async(tv.send_command('set_input', {'input': 'hdmi1'}))
                
                time.sleep(0.5)
        
        return jsonify({'success': True, 'stream_url': stream_url})
        
    except Exception as e:
        logger.error(f"Streaming start error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/streaming/stop', methods=['POST'])
def stop_streaming():
    """Stop streaming"""
    try:
        # Switch all TVs back to default input
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                run_async(tv.send_command('set_input', {'input': 'hdmi1'}))
                time.sleep(0.5)
        
        return jsonify({'success': True, 'message': 'Streaming stopped'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/content/custom', methods=['POST'])
def load_custom_content():
    """Load custom content URL"""
    data = request.get_json()
    content_url = data.get('url')
    
    if not content_url:
        return jsonify({'error': 'Content URL required'}), 400
    
    try:
        # Load custom content on all TVs
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                # Switch to network input
                run_async(tv.send_command('set_input', {'input': 'network'}))
                
                # Set URL if supported
                if tv.mdc and hasattr(tv.mdc, 'launcher_url_address'):
                    try:
                        run_async(tv.mdc.launcher_url_address(tv.config.display_id, [content_url]))
                    except Exception as e:
                        logger.warning(f"Could not set custom URL on TV {tv_id}: {e}")
                
                time.sleep(0.5)
        
        return jsonify({'success': True, 'content_url': content_url})
        
    except Exception as e:
        logger.error(f"Custom content error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/content/test', methods=['POST'])
def test_connection():
    """Test connection to content URL"""
    data = request.get_json()
    test_url = data.get('url')
    
    if not test_url:
        return jsonify({'error': 'URL required'}), 400
    
    try:
        import requests
        response = requests.get(test_url, timeout=10)
        
        return jsonify({
            'success': True,
            'status_code': response.status_code,
            'accessible': response.status_code == 200
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e),
            'accessible': False
        })

# Global control routes
@app.route('/api/global/power-on', methods=['POST'])
def all_power_on():
    """Turn on all displays"""
    try:
        results = []
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                result = run_async(tv.send_command('power_on'))
                results.append({'tv_id': tv_id, 'success': result.get('success')})
                time.sleep(1)  # Delay between power commands
        
        return jsonify({'success': True, 'results': results})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/global/power-off', methods=['POST'])
def all_power_off():
    """Turn off all displays"""
    try:
        results = []
        for tv_id, tv in video_wall.tvs.items():
            if tv.is_connected:
                result = run_async(tv.send_command('power_off'))
                results.append({'tv_id': tv_id, 'success': result.get('success')})
                time.sleep(1)
        
        return jsonify({'success': True, 'results': results})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/global/sync-inputs', methods=['POST'])
def sync_inputs():
    """Synchronize all inputs to match TV 1"""
    try:
        tv1 = video_wall.get_tv(1)
        if not tv1 or not tv1.is_connected:
            return jsonify({'error': 'TV 1 not available'}), 404
        
        # Get current input from TV 1
        reference_input = tv1.current_input
        
        results = []
        for tv_id in range(2, 5):  # TVs 2, 3, 4
            tv = video_wall.get_tv(tv_id)
            if tv and tv.is_connected:
                result = run_async(tv.send_command('set_input', {'input': reference_input}))
                results.append({'tv_id': tv_id, 'success': result.get('success')})
                time.sleep(0.3)
        
        return jsonify({'success': True, 'synced_input': reference_input, 'results': results})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/')
def index():
    """Serve the control panel info"""
    return jsonify({
        'message': 'Samsung Video Wall Control Panel Backend',
        'model': 'LH55BECHLGFXGO (BEC-H Series)',
        'version': '1.0.0',
        'mdc_available': MDC_AVAILABLE,
        'endpoints': {
            'tv_control': '/api/tv/{id}/{action}',
            'global_control': '/api/global/{action}',
            'video_wall': '/api/videowall/{action}',
            'content': '/api/content/{action}',
            'health': '/health'
        }
    })

@app.route('/health')
def health_check():
    """Health check endpoint"""
    tv_status = {}
    for tv_id, tv in video_wall.tvs.items():
        tv_status[f'tv_{tv_id}'] = {
            'connected': tv.is_connected,
            'ip': tv.config.ip_address,
            'display_id': tv.config.display_id,
            'position': tv.config.position
        }
    
    return jsonify({
        'status': 'healthy',
        'mdc_available': MDC_AVAILABLE,
        'video_wall_enabled': video_wall.video_wall_enabled,
        'magicinfo_server': video_wall.magicinfo_server,
        'current_preset': video_wall.current_preset,
        'tvs': tv_status
    })

# Configuration endpoint
@app.route('/api/config', methods=['GET', 'POST'])
def config():
    """Get or update configuration"""
    if request.method == 'GET':
        config_data = {
            'tvs': {
                tv_id: {
                    'name': tv.config.name,
                    'ip_address': tv.config.ip_address,
                    'display_id': tv.config.display_id,
                    'position': tv.config.position
                }
                for tv_id, tv in video_wall.tvs.items()
            },
            'video_wall_enabled': video_wall.video_wall_enabled,
            'magicinfo_server': video_wall.magicinfo_server
        }
        return jsonify(config_data)
    
    elif request.method == 'POST':
        # Update configuration (requires restart)
        return jsonify({'message': 'Configuration update requires server restart'})

if __name__ == '__main__':
    import atexit
    
    # Initialize video wall on startup
    if MDC_AVAILABLE:
        try:
            connection_results = run_async(video_wall.initialize())
            logger.info(f"Video wall initialization complete: {connection_results}")
        except Exception as e:
            logger.error(f"Video wall initialization failed: {e}")
    else:
        logger.warning("Samsung MDC library not available. Install with: pip install python-samsung-mdc")
    
    # Cleanup on exit
    def cleanup():
        if MDC_AVAILABLE:
            try:
                run_async(video_wall.cleanup())
                logger.info("Video wall cleanup complete")
            except Exception as e:
                logger.error(f"Cleanup error: {e}")
    
    atexit.register(cleanup)
    
    # Run Flask app
    logger.info("Starting Samsung Video Wall Control Panel Backend")
    logger.info("Access the frontend HTML file to control the video wall")
    app.run(host='0.0.0.0', port=5000, debug=True)