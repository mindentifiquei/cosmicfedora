#!/usr/bin/env bash
set -ox pipefail

# =========================================================================
# 1. BLOQUEIO DE REDE E ANTI-RASTREAMENTO (Corta conexões externas automáticas)
# =========================================================================
# Corta o ping automático para servidores do Fedora/RedHat
mkdir -p /usr/lib/NetworkManager/conf.d
cat << 'EOF' > /usr/lib/NetworkManager/conf.d/20-connectivity.conf
[connectivity]
enabled=false
EOF

# Desativa a captura de captive portals e conexões fantasmas em segundo plano
cat << 'EOF' > /usr/lib/NetworkManager/conf.d/30-privacy.conf
[device]
wifi.scan-rand-mac-address=yes
wifi.backend=iwd
EOF

# =========================================================================
# 2. SEGREGAÇÃO E MASCARAMENTO DE SERVIÇOS (Garante que o bloat nunca acorde)
# =========================================================================
systemctl enable opensnitch.service # Ativa o Firewall interativo
systemctl mask geoclue.service      # Morte definitiva ao serviço de localização
systemctl mask fwupd.service       # Impede checagem oculta de hardware em servidores
systemctl mask avahi-daemon.service # Bloqueia o PC de anunciar o seu nome na rede local
systemctl mask remote-desktop.target # Desativa completamente qualquer protocolo de acesso remoto

# =========================================================================
# 3. ENDURECIMENTO DO KERNEL (Sysctl Hardening estilo GrapheneOS)
# =========================================================================
# Protege contra ataques de rede e vazamento de dados locais via memória
mkdir -p /usr/lib/sysctl.d
cat << 'EOF' > /usr/lib/sysctl.d/99-hardened.conf
# Impede que usuários comuns vejam logs do kernel (protege contra exploits locais)
kernel.dmesg_restrict = 1

# Desativa o encapsulamento de roteamento que pode ser usado para clonar seu IP
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Ignora requisições de redirecionamento ICMP (evita ataques Man-in-the-Middle na sua rede)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Ativa proteção estrita contra IPs forjados (Reverse Path Filtering)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Desativa o protocolo IPv6 se você não usa (evita vazamento de IP real atrás de VPNs)
# Se sua operadora exigir IPv6, apague as duas linhas abaixo
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

# =========================================================================
# 4. PRIVACIDADE LOCAL (Impede o sistema de guardar metadados do seu uso)
# =========================================================================
# Desativa o core dump (gravação de dados da memória no SSD quando um app trava,
# o que pode expor senhas digitadas em texto puro nos arquivos de log)
cat << 'EOF' > /usr/lib/systemd/coredump.conf.d/disable.conf
[Coredump]
Storage=none
EOF

# Desativa o histórico recente do GNOME/COSMIC que rastreia arquivos abertos
mkdir -p /usr/share/glib-2.0/schemas
cat << 'EOF' > /usr/share/glib-2.0/schemas/99-privacy.gschema.override
[org.gnome.desktop.privacy]
remember-recent-files=false
remember-app-usage=false
send-stats=false
EOF
# Aplica a configuração de privacidade local na base do sistema
glib-compile-schemas /usr/share/glib-2.0/schemas
