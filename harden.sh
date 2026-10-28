#!/usr/bin/env bash
# =============================================================================
# harden.sh — roda DENTRO do build da imagem (módulo "script" do BlueBuild).
# Local no repositório: files/scripts/harden.sh
#
# O que faz:
#   1. Remove pacotes de telemetria/bloat que EXISTIREM na imagem base.
#      Nomes ausentes são ignorados. Remoção que quebraria dependências é
#      recusada pelo rpm-ostree e o pacote é mantido (listado no final).
#   2. Desliga a contagem "countme" do Fedora (método da documentação oficial).
#   3. Mascara serviços/timers que fazem tráfego de rede ou indexação.
#   4. Grava configurações de NetworkManager, systemd-resolved, sysctl,
#      coredump e GSettings.
#
# Teste local opcional (não mexe no sistema real, só num diretório falso):
#   HARDEN_ROOT=/tmp/raiz-falsa bash harden.sh
# =============================================================================
set -euo pipefail

ROOT="${HARDEN_ROOT:-}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
die()  { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

# Grava o conteúdo de stdin em ${ROOT}$1, criando o diretório se preciso.
write_file() {
  local dest="${ROOT}$1"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest"
}

# systemctl que funciona offline (durante o build) e em teste (--root).
sctl() {
  if [[ -n "$ROOT" ]]; then
    systemctl --root="$ROOT" "$@"
  else
    systemctl "$@"
  fi
}

# =============================================================================
# 1) REMOÇÃO DE PACOTES
# =============================================================================
log "1/7  Remoção de pacotes (apenas os que existirem na imagem)"

CANDIDATES=(
  # --- Navegador padrão (telemetria, estudos, buscas patrocinadas) ---------
  # Depois de remover, o módulo default-flatpaks do recipe.yml instala outro.
  firefox
  firefox-langpacks
  fedora-bookmarks

  # --- ABRT / relatórios automáticos de falhas ------------------------------
  abrt
  abrt-addon-ccpp
  abrt-addon-kerneloops
  abrt-addon-pstoreoops
  abrt-addon-vmcore
  abrt-addon-xorg
  abrt-cli
  abrt-dbus
  abrt-desktop
  abrt-gui
  abrt-tui
  abrt-plugin-bodhi
  gnome-abrt
  libreport-plugin-ureport

  # --- Coleta de diagnóstico / provisionamento em nuvem ---------------------
  sos
  NetworkManager-cloud-setup

  # --- Indexadores de arquivos ----------------------------------------------
  plocate
  mlocate
  tracker3
  tracker3-miners

  # --- Descoberta/compartilhamento na rede local ----------------------------
  avahi
  nss-mdns
  samba-client
  rygel

  # --- Impressão e biometria ------------------------------------------------
  cups
  cups-browsed
  cups-filters
  fprintd
  fprintd-pam

  # --- Apps do GNOME que não fazem sentido no COSMIC ------------------------
  gnome-tour
  totem

  # --- Opcional: descomente em hardware real. Em VM, mantenha (copiar/colar
  #     entre host e convidado e redimensionamento de tela dependem deles). ---
  # spice-vdagent
  # qemu-guest-agent

  # NÃO removidos de propósito:
  #   tcpdump                    útil para auditar o que sai da máquina
  #   pcsc-lite                  YubiKey / cartões OpenPGP (padrão aberto)
  #   cups-libs, avahi-libs ...  bibliotecas exigidas por GTK, Samba etc.
  #   fedora-logos, fedora-release-*  identidade do sistema (os-release);
  #                              outros pacotes dependem deles
  #   rng-tools                  alimenta a entropia do kernel; não envia nada
  #   geoclue2, fwupd            tratados por mascaramento (seção 3)
)

command -v rpm >/dev/null 2>&1         || die "rpm não encontrado."
command -v rpm-ostree >/dev/null 2>&1  || die "rpm-ostree não encontrado na imagem base."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

installed_names() { rpm -qa --qf '%{NAME}\n' | LC_ALL=C sort -u; }

present=()
absent=()
for pkg in "${CANDIDATES[@]}"; do
  if rpm -q --quiet "$pkg"; then
    present+=("$pkg")
  else
    absent+=("$pkg")
  fi
done

removed=()
kept=()
declare -A reason=()

if ((${#present[@]} > 0)); then
  installed_names > "$WORK/antes"
  echo "Presentes na imagem (${#present[@]}): ${present[*]}"

  # Tentativa 1: uma única transação com todos (resolve dependências entre eles).
  if rpm-ostree override remove "${present[@]}"; then
    removed=("${present[@]}")
  else
    warn "A remoção em lote falhou; tentando pacote a pacote (várias passadas)."
    pending=("${present[@]}")
    while ((${#pending[@]} > 0)); do
      progress=0
      next=()
      for pkg in "${pending[@]}"; do
        if ! rpm -q --quiet "$pkg"; then
          removed+=("$pkg")          # já saiu junto com outro pacote
          progress=1
        elif out="$(rpm-ostree override remove "$pkg" 2>&1)"; then
          removed+=("$pkg")
          progress=1
        else
          reason["$pkg"]="$(tail -n 1 <<<"$out")"
          next+=("$pkg")
        fi
      done
      pending=("${next[@]}")
      ((progress)) || break
    done
    kept=("${pending[@]}")
  fi

  # Trava de segurança: nada além da lista pode ter saído da imagem.
  installed_names > "$WORK/depois"
  mapfile -t gone < <(LC_ALL=C comm -23 "$WORK/antes" "$WORK/depois")
  declare -A wanted=()
  for pkg in "${CANDIDATES[@]}"; do wanted["$pkg"]=1; done
  unexpected=()
  for pkg in "${gone[@]}"; do
    [[ -n "${wanted[$pkg]:-}" ]] || unexpected+=("$pkg")
  done
  if ((${#unexpected[@]} > 0)); then
    die "A remoção levou junto pacotes que NÃO estavam na lista: ${unexpected[*]}"
  fi
fi

echo
echo "---- Resumo da remoção ----"
echo "Removidos (${#removed[@]}): ${removed[*]:-nenhum}"
echo "Ausentes na base, ignorados (${#absent[@]}): ${absent[*]:-nenhum}"
if ((${#kept[@]} > 0)); then
  warn "Mantidos (têm dependentes ou a remoção falhou): ${kept[*]}"
  for pkg in "${kept[@]}"; do
    printf '   %s -> %s\n' "$pkg" "${reason[$pkg]:-sem detalhe}"
  done
fi

# =============================================================================
# 2) CONTAGEM "COUNTME" DO FEDORA
#    Método da documentação oficial do Fedora para builds de contêiner:
#    countme=0 nos .repo + timer mascarado (seção 3).
# =============================================================================
log "2/7  Desligando a contagem 'countme' do Fedora"

shopt -s nullglob
repo_files=("${ROOT}"/etc/yum.repos.d/*.repo)
shopt -u nullglob
if ((${#repo_files[@]} > 0)); then
  sed -i -e 's,countme=1,countme=0,' "${repo_files[@]}"
  echo "countme=0 aplicado em ${#repo_files[@]} arquivo(s) .repo."
else
  warn "Nenhum arquivo .repo encontrado em /etc/yum.repos.d."
fi

# =============================================================================
# 3) SERVIÇOS E TIMERS MASCARADOS
#    Mascarar unidade inexistente é inofensivo (só cria o link para /dev/null).
# =============================================================================
log "3/7  Mascarando serviços e timers"

MASK_UNITS=(
  # Contagem de sistemas do Fedora
  rpm-ostree-countme.timer
  rpm-ostree-countme.service

  # Localização
  geoclue.service

  # Atualização AUTOMÁTICA de metadados de firmware. O fwupd em si continua
  # disponível sob demanda: rode "fwupdmgr refresh && fwupdmgr update".
  fwupd-refresh.timer
  fwupd-refresh.service

  # mDNS
  avahi-daemon.service
  avahi-daemon.socket

  # Impressão
  cups.service
  cups.socket
  cups.path
  cups-browsed.service

  # ABRT
  abrtd.service
  abrt-journal-core.service
  abrt-oops.service
  abrt-vmcore.service
  abrt-xorg.service
  abrt-pstoreoops.service
)
sctl mask "${MASK_UNITS[@]}"

# =============================================================================
# 4) REDE: NetworkManager e systemd-resolved
# =============================================================================
log "4/7  Configurando NetworkManager e systemd-resolved"

# Prefixo 90- para vencer qualquer arquivo de mesmo assunto enviado pelo Fedora.
write_file /usr/lib/NetworkManager/conf.d/90-privacidade.conf <<'EOF'
# Privacidade de rede (gerado por harden.sh)

[connectivity]
# Sem checagem periódica de conectividade (não consulta servidores do Fedora).
# Efeito colateral: sem detecção automática de portal cativo (Wi-Fi de hotel,
# aeroporto). Nesses casos, abra manualmente um site http:// (ex.: neverssl.com).
enabled=false

[device]
# MAC aleatório durante a varredura de redes Wi-Fi (já é o padrão).
wifi.scan-rand-mac-address=yes

[connection]
# MAC "estável por rede": diferente em cada rede, igual na mesma rede.
# Evita rastreio entre redes sem quebrar portais cativos nem reservas de DHCP.
wifi.cloned-mac-address=stable
ethernet.cloned-mac-address=stable
# IPv6 com endereços temporários (privacy extensions).
ipv6.ip6-privacy=2
EOF

write_file /usr/lib/systemd/resolved.conf.d/90-privacidade.conf <<'EOF'
[Resolve]
# Não anuncia nem consulta nomes na rede local via LLMNR / mDNS.
LLMNR=no
MulticastDNS=no
EOF

# =============================================================================
# 5) KERNEL: sysctl
# =============================================================================
log "5/7  Endurecendo o kernel (sysctl)"

write_file /usr/lib/sysctl.d/99-hardened.conf <<'EOF'
# Endurecimento (gerado por harden.sh). Prefixo 99- para vencer o 50-default.conf do systemd.

# --- Kernel -----------------------------------------------------------------
# Usuários comuns não leem o log do kernel.
kernel.dmesg_restrict = 1
# Sem eBPF para usuários sem privilégio; JIT do BPF endurecido (custo mínimo).
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
# Ninguém carrega outro kernel em tempo de execução (kexec).
kernel.kexec_load_disabled = 1
# Binários setuid não geram core dump.
fs.suid_dumpable = 0

# --- Rede (IPv4) ------------------------------------------------------------
# Sem roteamento de origem nem redirecionamentos ICMP (ataques man-in-the-middle).
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Filtro de caminho reverso em modo "loose" (2): bloqueia IP forjado sem quebrar
# VPN nem rotas assimétricas. O modo estrito (1) costuma causar problemas.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_rfc1337 = 1

# --- Rede (IPv6) ------------------------------------------------------------
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# --- IPv6 desativado? (DESLIGADO por padrão) ---------------------------------
# Descomente só se tem certeza de que sua rede funciona sem IPv6. Em redes
# somente-IPv6 (alguns planos móveis) a internet deixa de funcionar.
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF

# =============================================================================
# 6) PRIVACIDADE LOCAL: coredump e GSettings
# =============================================================================
log "6/7  Desativando coredumps e histórico recente (GTK/GNOME)"

# Core dumps podem conter senhas e chaves em texto puro.
write_file /usr/lib/systemd/coredump.conf.d/90-sem-coredump.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

# O COSMIC guarda suas preferências no cosmic-config e não lê este schema;
# o efeito vale para apps GTK/GNOME (ex.: lista de arquivos recentes).
SCHEMA_DIR="${ROOT}/usr/share/glib-2.0/schemas"
SCHEMA_XML="${SCHEMA_DIR}/org.gnome.desktop.privacy.gschema.xml"
if [[ -f "$SCHEMA_XML" ]]; then
  {
    echo "[org.gnome.desktop.privacy]"
    for key in remember-recent-files remember-app-usage \
               send-software-usage-stats report-technical-problems; do
      # Só escreve chaves que realmente existem no schema desta versão.
      if grep -q "name=\"${key}\"" "$SCHEMA_XML"; then
        echo "${key}=false"
      fi
    done
  } > "${SCHEMA_DIR}/99_privacidade.gschema.override"

  if command -v glib-compile-schemas >/dev/null 2>&1; then
    glib-compile-schemas "$SCHEMA_DIR"
  else
    warn "glib-compile-schemas não encontrado; override de privacidade não compilado."
  fi
else
  warn "Schema org.gnome.desktop.privacy ausente; pulando o override."
fi

# =============================================================================
# 7) OPENSNITCH (só se o módulo opcional do recipe.yml estiver ativado)
# =============================================================================
log "7/7  OpenSnitch"

if [[ -e "${ROOT}/usr/lib/systemd/system/opensnitchd.service" \
   || -e "${ROOT}/etc/systemd/system/opensnitchd.service" ]]; then
  sctl enable opensnitchd.service
  echo "opensnitchd.service habilitado."
else
  echo "OpenSnitch não instalado (módulo opcional do recipe.yml) — nada a fazer."
fi

log "harden.sh concluído."
