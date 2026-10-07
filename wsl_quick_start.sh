#!/bin/bash
# WSL Video Wall Control - Quick Start Script
# This script sets up and runs the video wall control system in WSL

set -e  # Exit on any error

echo "🎯 Samsung Video Wall Control - WSL Quick Start"
echo "================================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in WSL
check_wsl() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        print_success "Running in WSL environment"
        WSL_VERSION=$(grep -i microsoft /proc/version)
        echo "   $WSL_VERSION"
    else
        print_error "This script is designed for WSL environment"
        exit 1
    fi
}

# Check system requirements
check_requirements() {
    print_status "Checking system requirements..."
    
    # Check Python 3
    if command -v python3 &> /dev/null; then
        PYTHON_VERSION=$(python3 --version)
        print_success "Python found: $PYTHON_VERSION"
    else
        print_error "Python 3 not found. Installing..."
        sudo apt update
        sudo apt install -y python3 python3-pip python3-venv
    fi
    
    # Check pip
    if command -v pip3 &> /dev/null; then
        print_success "pip3 available"
    else
        print_error "pip3 not found"
        exit 1
    fi
    
    # Check network tools
    if ! command -v nc &> /dev/null; then
        print_warning "Installing network tools..."
        sudo apt install -y netcat-openbsd net-tools
    fi
}

# Setup Python virtual environment
setup_venv() {
    print_status "Setting up Python virtual environment..."
    
    if [ ! -d "venv" ]; then
        python3 -m venv venv
        print_success "Virtual environment created"
    else
        print_success "Virtual environment already exists"
    fi
    
    source venv/bin/activate
    
    # Install requirements
    if [ ! -f "requirements.txt" ]; then
        print_status "Creating requirements.txt..."
        cat > requirements.txt << 'EOF'
flask==2.3.3
flask-cors==4.0.0
python-samsung-mdc>=1.0.0
asyncio
EOF
    fi
    
    print_status "Installing Python packages..."
    pip install --upgrade pip
    pip install -r requirements.txt
    
    print_success "Python environment ready"
}

# Test network connectivity
test_network() {
    print_status "Testing network connectivity..."
    
    # Get WSL network info
    WSL_IP=$(hostname -I | awk '{print $1}')
    print_status "WSL IP address: $WSL_IP"
    
    # Test default TV IPs
    TV_IPS=("192.168.1.101" "192.168.1.102" "192.168.1.103" "192.168.1.104")
    
    echo "Testing TV connectivity:"
    for ip in "${TV_IPS[@]}"; do
        if ping -c 1 -W 2 "$ip" &> /dev/null; then
            print_success "TV at $ip is reachable"
            
            # Test MDC port
            if nc -z -w 2 "$ip" 1515 2>/dev/null; then
                print_success "   MDC port 1515 is open on $ip"
            else
                print_warning "   MDC port 1515 is not accessible on $ip"
            fi
        else
            print_warning "TV at $ip is not reachable"
        fi
    done
}

# Create configuration file
create_config() {
    print_status "Creating configuration..."
    
    if [ ! -f "config.json" ]; then
        cat > config.json << 'EOF'
{
    "tvs": {
        "1": {
            "name": "Top Left",
            "ip": "192.168.1.101",
            "display_id": 1,
            "position": "top-left"
        },
        "2": {
            "name": "Top Right", 
            "ip": "192.168.1.102",
            "display_id": 2,
            "position": "top-right"
        },
        "3": {
            "name": "Bottom Left",
            "ip": "192.168.1.103", 
            "display_id": 3,
            "position": "bottom-left"
        },
        "4": {
            "name": "Bottom Right",
            "ip": "192.168.1.104",
            "display_id": 4,
            "position": "bottom-right"
        }
    },
    "server": {
        "host": "0.0.0.0",
        "port": 5000,
        "debug": false
    }
}
EOF
        print_success "Configuration file created"
    else
        print_success "Configuration file already exists"
    fi
}

# Start the video wall backend
start_backend() {
    print_status "Starting video wall backend..."
    
    if [ ! -f "video_wall_backend.py" ]; then
        print_error "video_wall_backend.py not found!"
        print_status "Please ensure the backend Python file is in the current directory"
        exit 1
    fi
    
    source venv/bin/activate
    
    print_success "Backend starting on http://localhost:5000"
    print_success "WSL IP: $(hostname -I | awk '{print $1}')"
    print_status "Press Ctrl+C to stop the server"
    echo
    
    python3 video_wall_backend.py
}

# Stop any running backend
stop_backend() {
    print_status "Stopping any running video wall backend..."
    
    # Find and kill any running Python processes with video_wall_backend
    PIDS=$(pgrep -f "video_wall_backend.py" || true)
    
    if [ -n "$PIDS" ]; then
        for pid in $PIDS; do
            print_status "Stopping process $pid"
            kill "$pid" 2>/dev/null || true
        done
        sleep 2
        print_success "Backend stopped"
    else
        print_status "No running backend found"
    fi
}

# Show help
show_help() {
    echo "WSL Video Wall Control - Quick Start Script"
    echo
    echo "Usage: $0 [COMMAND]"
    echo
    echo "Commands:"
    echo "  setup     - Install dependencies and setup environment"
    echo "  start     - Start the video wall backend server"
    echo "  stop      - Stop the video wall backend server"
    echo "  test      - Test network connectivity to TVs"
    echo "  status    - Show system status"
    echo "  install   - Full installation and setup"
    echo "  help      - Show this help message"
    echo
    echo "Examples:"
    echo "  $0 install    # Full setup from scratch"
    echo "  $0 start      # Start the backend server"
    echo "  $0 test       # Test TV connectivity"
    echo
}

# Show system status
show_status() {
    print_status "Video Wall Control System Status"
    echo "================================="
    
    check_wsl
    
    # Check if venv exists
    if [ -d "venv" ]; then
        print_success "Virtual environment: Ready"
    else
        print_warning "Virtual environment: Not created"
    fi
    
    # Check if backend file exists
    if [ -f "video_wall_backend.py" ]; then
        print_success "Backend file: Present"
    else
        print_error "Backend file: Missing"
    fi
    
    # Check if backend is running
    if pgrep -f "video_wall_backend.py" &> /dev/null; then
        print_success "Backend server: Running"
        BACKEND_PID=$(pgrep -f "video_wall_backend.py")
        echo "   PID: $BACKEND_PID"
    else
        print_warning "Backend server: Not running"
    fi
    
    # Network info
    WSL_IP=$(hostname -I | awk '{print $1}')
    print_status "WSL IP address: $WSL_IP"
    