#!/bin/bash
# сканирует эфир, ищет целевые устройства
# результаты пишутся в logs/scan-01.csv

mkdir -p logs

echo "[log] сканируем 20 секунд на wlan1mon"
echo "[log] смотрим: TP-Link_5E56 (D8:0D:17:7F:5E:56) и лампочку (fe:3c:d7)"

# запускаем в фоне, вывод в /dev/null чтобы не спамил
airodump-ng --output-format csv --write logs/scan wlan1mon > /dev/null 2>&1 &
PID=$!

# показываем прогресс
for i in $(seq 1 20); do
    echo -ne "\r[log] прошло $i/20 сек..."
    sleep 1
done
echo ""

kill $PID 2>/dev/null
wait $PID 2>/dev/null

echo "[log] результаты:"
# выводим найденные AP из csv (пропускаем заголовок)
awk -F',' 'NR>2 && /^([0-9A-Fa-f]{2}:){5}/ {
    gsub(/ /, "", $1); gsub(/ /, "", $4); gsub(/ /, "", $14)
    printf "  BSSID=%-20s CH=%-4s SSID=%s\n", $1, $4, $14
}' logs/scan-01.csv 2>/dev/null

echo ""
echo "[log] лампочка как клиент:"
awk '/^Station/,0' logs/scan-01.csv | \
    awk -F',' '/fe:3c:d7/ { gsub(/ /,"",$1); gsub(/ /,"",$6); print "  MAC="$1"  ->  AP="$6 }'

# сохраняем канал домашнего AP
CHANNEL=$(awk -F',' 'NR>2 && /D8:0D:17:7F:5E:56/ { gsub(/ /,"",$4); print $4 }' logs/scan-01.csv | head -1)
if [ -n "$CHANNEL" ]; then
    echo $CHANNEL > logs/home_channel.txt
    echo "[log] канал домашнего AP: $CHANNEL (сохранён в logs/home_channel.txt)"
fi
