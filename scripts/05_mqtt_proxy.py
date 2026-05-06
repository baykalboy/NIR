#!/usr/bin/env python3
# MQTT over TLS прокси для перехвата трафика лампочки
# слушает на порту 18883, iptables редиректит туда трафик с 8883
# пробует установить TLS с лампочкой и форвардит к реальному серверу

import asyncio
import ssl
import json
from datetime import datetime

LISTEN_PORT  = 18883
REMOTE_HOST  = "odm.iot.sberdevices.ru"
REMOTE_PORT  = 8883
CERT_FILE    = "certs/server.crt"
KEY_FILE     = "certs/server.key"
LOG_FILE     = "logs/mqtt_messages.jsonl"

# типы MQTT пакетов
MQTT_TYPES = {
    1: "CONNECT", 2: "CONNACK", 3: "PUBLISH", 4: "PUBACK",
    8: "SUBSCRIBE", 9: "SUBACK", 12: "PINGREQ", 13: "PINGRESP", 14: "DISCONNECT"
}

def parse_mqtt(data):
    """разбираем MQTT пакет — достаём тип и основные поля"""
    if len(data) < 2:
        return None

    pkt_type = (data[0] >> 4) & 0x0F
    result = {"type": MQTT_TYPES.get(pkt_type, f"UNKNOWN({pkt_type})")}

    # длина остатка пакета
    mul, rem_len, i = 1, 0, 1
    while i < len(data) and i < 5:
        b = data[i]; i += 1
        rem_len += (b & 0x7F) * mul
        mul *= 128
        if not (b & 0x80):
            break

    payload = data[i: i + rem_len]

    try:
        if pkt_type == 3:  # PUBLISH
            # читаем топик
            tlen = (payload[0] << 8) | payload[1]
            topic = payload[2: 2 + tlen].decode("utf-8", errors="replace")
            msg = payload[2 + tlen:]
            result["topic"] = topic
            try:
                result["payload"] = json.loads(msg)
            except Exception:
                result["payload"] = msg.decode("utf-8", errors="replace")[:300]

        elif pkt_type == 1:  # CONNECT
            # пропускаем protocol name (2+4 байта) и version (1 байт)
            flags = payload[7]
            keepalive = (payload[8] << 8) | payload[9]
            off = 10
            # client_id
            clen = (payload[off] << 8) | payload[off+1]; off += 2
            result["client_id"] = payload[off: off + clen].decode("utf-8", errors="replace")
            off += clen
            # username
            if flags & 0x80:
                ulen = (payload[off] << 8) | payload[off+1]; off += 2
                result["username"] = payload[off: off + ulen].decode("utf-8", errors="replace")
                off += ulen
            # password
            if flags & 0x40:
                plen = (payload[off] << 8) | payload[off+1]; off += 2
                result["password_hex"] = payload[off: off + plen].hex()

        elif pkt_type == 8:  # SUBSCRIBE
            off = 2  # packet id
            topics = []
            while off < len(payload):
                tlen = (payload[off] << 8) | payload[off+1]; off += 2
                topics.append(payload[off: off + tlen].decode("utf-8", errors="replace"))
                off += tlen + 1
            result["topics"] = topics

    except Exception as e:
        result["parse_error"] = str(e)

    return result


def log_packet(direction, data):
    """логируем пакет в консоль и в jsonl файл"""
    pkt = parse_mqtt(data)
    ts = datetime.now().strftime("%H:%M:%S")
    arrow = "->" if direction == "bulb" else "<-"

    if pkt:
        t = pkt.get("type", "?")
        extra = ""
        if t == "PUBLISH":
            extra = f"  topic={pkt.get('topic')}  payload={pkt.get('payload')}"
        elif t == "CONNECT":
            extra = f"  client_id={pkt.get('client_id')}  user={pkt.get('username', '-')}"
        elif t == "SUBSCRIBE":
            extra = f"  topics={pkt.get('topics')}"
        print(f"[{ts}] {arrow} {t}{extra}")

    entry = {
        "ts": ts,
        "dir": direction,
        "mqtt": pkt,
        "raw": data[:64].hex()
    }
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


async def pipe(reader, writer, direction):
    """читаем данные из одного потока и пишем в другой, логируем"""
    buf = b""
    try:
        while True:
            chunk = await reader.read(4096)
            if not chunk:
                break
            buf += chunk
            # пробуем вытащить пакеты из буфера
            while len(buf) >= 2:
                mul, rem, i = 1, 0, 1
                while i < len(buf) and i < 5:
                    b = buf[i]; i += 1
                    rem += (b & 0x7F) * mul
                    mul *= 128
                    if not (b & 0x80):
                        break
                total = i + rem
                if len(buf) < total:
                    break
                log_packet(direction, buf[:total])
                buf = buf[total:]
            writer.write(chunk)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_r, client_w):
    """обрабатываем подключение от лампочки"""
    peer = client_w.get_extra_info("peername")
    print(f"[log] подключение от {peer}")

    # подключаемся к реальному MQTT серверу
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        remote_r, remote_w = await asyncio.open_connection(REMOTE_HOST, REMOTE_PORT, ssl=ctx)
        print(f"[log] подключились к {REMOTE_HOST}:{REMOTE_PORT}")
    except Exception as e:
        print(f"[log] не удалось подключиться к серверу: {e}")
        client_w.close()
        return

    t1 = asyncio.create_task(pipe(client_r, remote_w, "bulb"))
    t2 = asyncio.create_task(pipe(remote_r, client_w, "cloud"))
    done, pending = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()
    print(f"[log] сессия {peer} закрыта")


async def main():
    # TLS контекст — предъявляем лампочке наш сертификат
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)

    server = await asyncio.start_server(handle, "0.0.0.0", LISTEN_PORT, ssl=ctx)
    print(f"[log] MQTT прокси слушает на порту {LISTEN_PORT}")
    print(f"[log] форвардинг -> {REMOTE_HOST}:{REMOTE_PORT}")
    print(f"[log] лог: {LOG_FILE}")

    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("[log] остановлено")
