#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup.sh - Installs and configures NUT on a Raspberry Pi, making it a UPS
#            server. Follows the PiMyLifeUp how-to, with added prompts for
#            driver/device selection and network interface settings.
#
# Usage: sudo ./setup.sh
###############################################################################

# Default values
DEFAULT_UPS_NAME="myups"
DEFAULT_NUT_USER="upsmonuser"
DEFAULT_NUT_PASS="secretpassword"
DEFAULT_DRIVER="usbhid-ups"

# Check for sudo
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Please run this script with sudo or as root."
  exit 1
fi

# 1. Update and install NUT packages if needed
echo "Updating packages and installing NUT..."
apt-get update -y
apt-get install -y nut ups-tools

echo "NUT installation ensured."

# 2. Prompt user to list USB devices and select a UPS
echo "Detecting USB devices with lsusb..."
lsusb || { echo "ERROR: lsusb command failed. Exiting."; exit 1; }

echo
echo "Above are your USB devices. Please identify your UPS from the list."
read -rp "Enter any identifiable part of your UPS line (e.g. 'AAAA:BBBB' or manufacturer). Leave blank if unsure: " UPS_FILTER

if [[ -z "$UPS_FILTER" ]]; then
  echo "No filter provided. We'll just assume 'auto' port in configuration."
  UPS_PORT="auto"
else
  MATCHES=$(lsusb | grep -i "$UPS_FILTER" || true)
  if [[ -z "$MATCHES" ]]; then
    echo "No matching devices found for '$UPS_FILTER'. Falling back to 'auto'."
    UPS_PORT="auto"
  else
    echo "Found these matches:"
    echo "$MATCHES"
    echo "Typically, we still use 'auto' for USB-based UPS devices."
    UPS_PORT="auto"
  fi
fi

# 3. Ask which driver to use, fallback to usbhid-ups if blank
read -rp "Enter the NUT driver to use (default: $DEFAULT_DRIVER): " SELECTED_DRIVER
UPS_DRIVER="${SELECTED_DRIVER:-$DEFAULT_DRIVER}"

echo "Using driver: $UPS_DRIVER"
echo "Using port: $UPS_PORT"

# 4. Configure /etc/nut/ups.conf
UPS_CONF_FILE="/etc/nut/ups.conf"
echo "Configuring $UPS_CONF_FILE..."

if [[ -f "$UPS_CONF_FILE" ]]; then
  cp "$UPS_CONF_FILE" "${UPS_CONF_FILE}.bak.$(date +%s)"
fi

cat > "$UPS_CONF_FILE" <<EOF
[$DEFAULT_UPS_NAME]
    driver = $UPS_DRIVER
    port = $UPS_PORT
    desc = "My UPS"
EOF

echo "Successfully wrote $UPS_CONF_FILE."

# 5. Configure /etc/nut/nut.conf for standalone mode
NUT_CONF="/etc/nut/nut.conf"
if [[ -f "$NUT_CONF" ]]; then
  cp "$NUT_CONF" "${NUT_CONF}.bak.$(date +%s)"
fi

echo "MODE=standalone" > "$NUT_CONF"
echo "Configured standalone mode in $NUT_CONF."

# 6. Configure /etc/nut/upsd.conf
UPSD_CONF="/etc/nut/upsd.conf"
if [[ -f "$UPSD_CONF" ]]; then
  cp "$UPSD_CONF" "${UPSD_CONF}.bak.$(date +%s)"
fi

cat > "$UPSD_CONF" <<EOF
LISTEN 127.0.0.1 3493
EOF

echo "Wrote default listen config to $UPSD_CONF."

# 6.1 Optionally prompt to install net-tools and view IP addresses with ifconfig
echo
read -rp "Do you want to configure external network access now? [y/N]: " NET_ACCESS
NET_ACCESS="${NET_ACCESS,,}"  # convert to lowercase

if [[ "$NET_ACCESS" == "y" ]]; then
  # Ensure ifconfig is available
  if ! command -v ifconfig &>/dev/null; then
    echo "'ifconfig' not found. Installing net-tools..."
    apt-get install -y net-tools
  fi

  echo "Your current network interfaces (via ifconfig):"
  ifconfig || { echo "ERROR: ifconfig command failed. Exiting."; exit 1; }

  read -rp "Enter the Raspberry Pi IP address you want NUT to listen on (blank to skip): " SELECTED_IP
  if [[ -n "$SELECTED_IP" ]]; then
    # Simple sanity check for IPv4 format
    if [[ "$SELECTED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Adding 'LISTEN $SELECTED_IP 3493' to $UPSD_CONF..."
      echo "LISTEN $SELECTED_IP 3493" >> "$UPSD_CONF"
    else
      echo "WARNING: '$SELECTED_IP' doesn't look like a valid IPv4 address. Skipping."
    fi
  fi
fi

# 7. Configure /etc/nut/upsd.users
UPSD_USERS="/etc/nut/upsd.users"
if [[ -f "$UPSD_USERS" ]]; then
  cp "$UPSD_USERS" "${UPSD_USERS}.bak.$(date +%s)"
fi

cat > "$UPSD_USERS" <<EOF
[$DEFAULT_NUT_USER]
  password = $DEFAULT_NUT_PASS
  upsmon master
EOF

echo "Created $UPSD_USERS with user '$DEFAULT_NUT_USER'."

# 8. Configure /etc/nut/upsmon.conf
UPSMON_CONF="/etc/nut/upsmon.conf"
if [[ -f "$UPSMON_CONF" ]]; then
  cp "$UPSMON_CONF" "${UPSMON_CONF}.bak.$(date +%s)"
fi

cat > "$UPSMON_CONF" <<EOF
MONITOR $DEFAULT_UPS_NAME@localhost 1 $DEFAULT_NUT_USER $DEFAULT_NUT_PASS master
SHUTDOWNCMD "/sbin/shutdown -h now"
EOF

echo "Created $UPSMON_CONF to monitor $DEFAULT_UPS_NAME."

# 9. Enable and start NUT services
echo "Enabling and starting NUT services..."
systemctl enable nut-server.service || true
systemctl enable nut-monitor.service || true
systemctl start nut-server.service
systemctl start nut-monitor.service

# 10. Quick test
echo "Attempting a quick test with upsc..."
if upsc "${DEFAULT_UPS_NAME}@localhost" &>/dev/null; then
  echo "Test successful: NUT is running, and UPS is recognized."
else
  echo "WARNING: 'upsc' test failed. Verify your UPS driver/connection."
fi

echo
echo "Setup complete. For additional network access, see $UPSD_CONF."
echo "Restart services if you make changes: sudo systemctl restart nut-server nut-monitor"
echo "Done!"
