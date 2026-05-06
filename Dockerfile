FROM mcr.microsoft.com/devcontainers/base:ubuntu

RUN apt-get update && apt-get install -y \
    curl git python3 python3-pip bash \
    # Сетевые инструменты
    nmap netcat-traditional tcpdump \
    wireshark tshark \
    aircrack-ng iw wireless-tools \
    python3-scapy \
    iproute2 iputils-ping net-tools \
    # MQTT
    mosquitto-clients \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

RUN npm install -g @anthropic-ai/claude-code

WORKDIR /workspace