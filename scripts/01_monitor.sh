#!/bin/bash
# переводит wlan1 в monitor mode и обратно
# использование: ./01_monitor.sh start | stop

IFACE="wlan1"

if [ "$1" = "start" ]; then
    echo "[log] убиваем процессы которые мешают monitor mode"
    airmon-ng check kill

    echo "[log] включаем monitor mode на $IFACE"
    airmon-ng start $IFACE

    # после airmon-ng интерфейс переименовывается в wlan1mon
    echo "[log] готово, интерфейс теперь wlan1mon"
    iwconfig wlan1mon

elif [ "$1" = "stop" ]; then
    echo "[log] выключаем monitor mode"
    airmon-ng stop wlan1mon

    echo "[log] перезапускаем NetworkManager"
    service NetworkManager start

else
    echo "использование: $0 start | stop"
fi
