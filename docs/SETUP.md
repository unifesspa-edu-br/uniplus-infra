# Setup do Laboratório

> Passo-a-passo para preparar as duas máquinas do laboratório de validação arquitetural do Uni+.

## Visão geral

O laboratório consiste em **duas máquinas físicas** simulando os DCs SP1 e SP2 da EVEO, mais um **container isolado** simulando a infraestrutura interna da UNIFESSPA. As máquinas se comunicam pela rede LAN local (gigabit), com domínio público acessível via Cloudflare Tunnel.

| Papel | Máquina | Hostname sugerido | IP estático |
|-------|---------|-------------------|-------------|
| EVEO SP1 simulado | Ryzen 9 9950X | `uniplus-sp1` | `192.168.0.10` |
| EVEO SP2 simulado | Core i7 12ª gen | `uniplus-sp2` | `192.168.0.20` |
| UNIFESSPA witness | Container na máquina i7 | `uniplus-witness` | rede interna isolada |

## Pré-requisitos

- 2 máquinas físicas conforme especificações em [VALIDATION-PLAN.md](VALIDATION-PLAN.md#32-mapeamento-de-hardware)
- Domínio registrado (`uniplus-lab.shop` ou outro) com DNS no Cloudflare
- Conta gratuita no Cloudflare (`dash.cloudflare.com`)
- Conta no GitHub com acesso à org `unifesspa-edu-br`
- Roteador local com possibilidade de IP fixo (DHCP reservation)

## Sumário

- [1. Preparação das máquinas](#1-preparação-das-máquinas)
- [2. Instalação de Linux](#2-instalação-de-linux)
- [3. Configuração de rede](#3-configuração-de-rede)
- [4. Hardening básico](#4-hardening-básico)
- [5. Instalação do runtime de containers](#5-instalação-do-runtime-de-containers)
- [6. Instalação do Kubernetes (K3s)](#6-instalação-do-kubernetes-k3s)
- [7. Configuração do Cloudflare Tunnel](#7-configuração-do-cloudflare-tunnel)
- [8. Componentes stateful no host](#8-componentes-stateful-no-host)
- [9. Witness UNIFESSPA simulada](#9-witness-unifesspa-simulada)
- [10. Validação final](#10-validação-final)
- [11. Troubleshooting](#11-troubleshooting)

## 1. Preparação das máquinas

### 1.1 Máquina principal (Ryzen 9950X)

Já está em uso como workstation com **Arch Linux**. Manter Arch Linux.

**O que fazer:**

1. Atualizar o sistema antes de iniciar:
   ```bash
   sudo pacman -Syu
   ```
2. Definir hostname:
   ```bash
   sudo hostnamectl set-hostname uniplus-sp1
   ```
3. Reservar IP fixo no roteador para a interface de rede principal.

### 1.2 Máquina secundária (Core i7 12ª gen)

Atualmente com Windows + WSL2. Recomenda-se **substituir por Ubuntu Server 24.04 LTS** (mesmo SO que será usado nos servidores EVEO em produção).

**Razões para Ubuntu Server (não Arch nesta máquina):**

- LTS — sem surpresas em servidor que fica ligado direto
- Mesmo OS de produção EVEO — comportamento idêntico
- Sem GUI — menor footprint, mais RAM disponível
- Suporte amplo para K3s, Docker, Helm

## 2. Instalação de Linux

### 2.1 Instalação do Ubuntu Server na máquina i7

1. Baixar Ubuntu Server 24.04 LTS: https://ubuntu.com/download/server
2. Criar USB bootável (Rufus no Windows ou `dd` no Linux)
3. Bootar pela USB e seguir o instalador:
   - **Storage:** usar disco inteiro com LVM (vai facilitar volumes para Postgres/Kafka/MinIO)
   - **Profile:**
     - Hostname: `uniplus-sp2`
     - Username: `jeferson` (ou seu padrão)
   - **SSH Setup:** habilitar OpenSSH, importar chave do GitHub se preferir
   - **Snaps:** desabilitar todos (instalaremos pacotes via apt)
4. Após instalação, login e atualização:
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y curl wget vim git htop iotop net-tools tcpdump build-essential
   ```

### 2.2 Particionamento recomendado (i7 com 1 TB NVMe)

```
/                  50 GB    (sistema)
/var               100 GB   (logs, Docker, etc)
/var/lib/postgres  200 GB   (volumes Postgres)
/var/lib/kafka     100 GB   (volumes Kafka)
/var/lib/minio     400 GB   (volumes MinIO)
swap               8 GB     (zswap recomendado)
free               restante (margem)
```

Use LVM para flexibilidade futura de redimensionamento.

### 2.3 Particionamento recomendado (Ryzen com 2 TB NVMe)

Mesma lógica, com volumes maiores:

```
/                  60 GB
/var               150 GB
/var/lib/postgres  400 GB
/var/lib/kafka     300 GB
/var/lib/minio     800 GB
swap               16 GB
free               restante
```

## 3. Configuração de rede

### 3.1 IP fixo via DHCP reservation

Acesse o painel do roteador TIM Fibra:
1. Encontre as reservações DHCP
2. Reserve IPs para os MAC addresses das duas máquinas:
   - `uniplus-sp1` → `192.168.0.10`
   - `uniplus-sp2` → `192.168.0.20`

### 3.2 Configuração de hostnames cruzados

Em **ambas as máquinas**, edite `/etc/hosts`:

```bash
# /etc/hosts
192.168.0.10  uniplus-sp1
192.168.0.20  uniplus-sp2
192.168.0.21  uniplus-witness  # IP da bridge interna no container
```

### 3.3 Validação de conectividade

```bash
# Da Ryzen para i7
ping -c 4 uniplus-sp2

# Da i7 para Ryzen
ping -c 4 uniplus-sp1

# Latência esperada: < 1 ms RTT
```

### 3.4 (Opcional) Adicionar latência artificial

Para simular o L2L EVEO realisticamente em testes específicos:

```bash
# Adiciona 1ms de latência simulada (~ produção)
sudo tc qdisc add dev <interface> root netem delay 1ms

# Para testes de degradação:
sudo tc qdisc add dev <interface> root netem delay 5ms 2ms loss 0.1%

# Remove
sudo tc qdisc del dev <interface> root
```

## 4. Hardening básico

### 4.1 SSH

**Em ambas as máquinas:**

```bash
# Editar /etc/ssh/sshd_config
sudo vim /etc/ssh/sshd_config
```

Aplicar:
```
PermitRootLogin no
PasswordAuthentication no       # apenas chave SSH
PubkeyAuthentication yes
X11Forwarding no
ClientAliveInterval 300
```

```bash
sudo systemctl restart sshd
```

### 4.2 Firewall (ufw)

**Na máquina i7 (Ubuntu):**

```bash
sudo ufw allow from 192.168.0.0/24 to any port 22 proto tcp     # SSH só na LAN
sudo ufw allow from 192.168.0.10 to any                         # Tudo do uniplus-sp1
sudo ufw allow 6443/tcp                                          # K3s API server
sudo ufw allow 10250/tcp                                         # Kubelet
sudo ufw allow 8472/udp                                          # Flannel VXLAN
sudo ufw enable
sudo ufw status verbose
```

**Na Ryzen (Arch com iptables ou ufw, conforme já configurado).**

### 4.3 Atualizações automáticas (Ubuntu)

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

### 4.4 fail2ban (proteção contra brute-force SSH)

```bash
# Ubuntu
sudo apt install -y fail2ban
sudo systemctl enable --now fail2ban

# Arch
sudo pacman -S fail2ban
sudo systemctl enable --now fail2ban
```

## 5. Instalação do runtime de containers

### 5.1 Docker (recomendado para containers no host: Postgres, Kafka, MinIO)

**Ubuntu:**
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
docker --version
```

**Arch:**
```bash
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
```

### 5.2 docker-compose

```bash
# Ubuntu
sudo apt install -y docker-compose-plugin

# Arch já vem com docker-compose
docker compose version
```

## 6. Instalação do Kubernetes (K3s)

### 6.1 Por que K3s

K3s é uma distribuição Kubernetes certificada, leve e otimizada para edge/single-node. Comparado a kubeadm tradicional ou KIND, oferece:

- ✅ Single binary, instalação em um comando
- ✅ Vem com Traefik pré-instalado (já alinhado com nossa arquitetura)
- ✅ containerd como runtime (mesmo de produção)
- ✅ Operação real (não simulação Docker-in-Docker)
- ✅ Excelente performance no hardware do lab

### 6.2 Instalação no `uniplus-sp1` (Ryzen)

```bash
# Instalar K3s server
curl -sfL https://get.k3s.io | sh -s - \
    --node-name uniplus-sp1 \
    --cluster-init \
    --tls-san uniplus-sp1 \
    --tls-san 192.168.0.10 \
    --disable servicelb \
    --write-kubeconfig-mode 644

# Verificar
sudo systemctl status k3s
sudo kubectl get nodes
```

**Observação:** estamos desabilitando o `servicelb` padrão porque vamos usar **MetalLB** depois (mais flexível). Mantemos o Traefik que vem como ingress controller.

### 6.3 Instalação no `uniplus-sp2` (i7)

```bash
# Instalar K3s como cluster INDEPENDENTE (não worker do SP1!)
curl -sfL https://get.k3s.io | sh -s - \
    --node-name uniplus-sp2 \
    --cluster-init \
    --tls-san uniplus-sp2 \
    --tls-san 192.168.0.20 \
    --disable servicelb \
    --write-kubeconfig-mode 644
```

⚠️ **Importante:** os dois clusters são **independentes**. Não use `--server` apontando para o outro cluster — isso criaria um único cluster estendido, contra a decisão arquitetural.

### 6.4 Configurar kubectl localmente

```bash
# Em ambas as máquinas
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# Renomear contextos para clareza
kubectl config rename-context default uniplus-sp1   # ou sp2 conforme a máquina

# Validar
kubectl get nodes
kubectl get pods -A
```

### 6.5 Instalar utilitários

```bash
# Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# k9s (terminal UI)
# Ubuntu
curl -sS https://webinstall.dev/k9s | bash

# Arch
sudo pacman -S k9s

# kubectx + kubens
# Ubuntu
sudo apt install -y kubectx

# Arch
sudo pacman -S kubectx
```

## 7. Configuração do Cloudflare Tunnel

### 7.1 Pré-requisitos

1. Conta Cloudflare gratuita
2. Domínio `uniplus-lab.shop` adicionado à conta Cloudflare (NS apontando para Cloudflare)
3. Acesso de admin ao painel Cloudflare

### 7.2 Instalação do `cloudflared`

**Em ambas as máquinas:**

```bash
# Baixar binário oficial
curl -L \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /tmp/cloudflared
sudo install /tmp/cloudflared /usr/local/bin/cloudflared

# Verificar
cloudflared --version
```

### 7.3 Login na conta Cloudflare

```bash
cloudflared tunnel login
# abre browser para autorização — escolher o domínio uniplus-lab.shop
```

### 7.4 Criar tunnel para SP1

**Na Ryzen:**

```bash
cloudflared tunnel create uniplus-lab-sp1
# anote o tunnel-id retornado

# Configuração
mkdir -p ~/.cloudflared
cat > ~/.cloudflared/config.yml <<EOF
tunnel: <tunnel-id-aqui>
credentials-file: /home/$USER/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: uniplus-lab.shop
    service: http://localhost:80
  - hostname: "*.uniplus-lab.shop"
    service: http://localhost:80
  - service: http_status:404
EOF

# Configurar rotas DNS
cloudflared tunnel route dns uniplus-lab-sp1 uniplus-lab.shop
cloudflared tunnel route dns uniplus-lab-sp1 "*.uniplus-lab.shop"

# Instalar como serviço systemd
sudo cloudflared service install
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
```

### 7.5 Tunnel para SP2 (load balancing)

**Na i7:**

Repita o processo criando `uniplus-lab-sp2` com **outro tunnel-id**, mas apontando para os **mesmos hostnames**. Cloudflare detectará automaticamente os múltiplos tunnels e fará load balancing entre eles.

⚠️ **Alternativa:** usar 1 tunnel único com 2 instâncias `cloudflared` (uma em cada máquina) compartilhando as credenciais via Vault. Para o lab, criar 2 tunnels separados é mais simples.

### 7.6 Validação

Após alguns minutos para propagação DNS:

```bash
# De qualquer rede externa:
curl -v https://uniplus-lab.shop
# deve retornar 404 (esperado, ainda não há ingress configurado)
# mas com TLS válido emitido pelo Cloudflare
```

## 8. Componentes stateful no host

PostgreSQL, Kafka e MinIO rodam fora do K8s, em containers Docker gerenciados via systemd. Os arquivos de configuração e `docker-compose.yml` ficam em `data/` deste repositório.

### 8.1 PostgreSQL com Patroni

Veja [data/postgres/README.md](../data/postgres/README.md) para detalhes específicos de:

- Configuração do Patroni com 3 nós etcd (incluindo witness)
- Distribuição de primaries (Portal e Ingresso em SP1, Seleção em SP2)
- PgBouncer como pool de conexões
- pgBackRest para backups

### 8.2 Apache Kafka (KRaft mode)

Veja [data/kafka/README.md](../data/kafka/README.md) para:

- Configuração KRaft (sem ZooKeeper)
- 3 brokers distribuídos entre os DCs
- MirrorMaker 2 para replicação inter-DC

### 8.3 MinIO Distribuído

Veja [data/minio/README.md](../data/minio/README.md) para:

- 4 nós lógicos (2 por DC)
- Erasure coding configurado
- Buckets `quarentena/`, `aprovado/`, `bloqueado/`
- Replicação assíncrona para MinIO master simulada

## 9. Witness UNIFESSPA simulada

O container `uniplus-witness` simula a infraestrutura interna da UNIFESSPA (etcd witness, Keycloak Master, MinIO master). Vamos rodá-lo na máquina i7 em uma **rede Docker isolada**.

### 9.1 Criar rede isolada

```bash
# Na máquina i7
docker network create --subnet 172.30.0.0/16 unifesspa-sim
```

### 9.2 Subir os serviços simulados

```bash
cd uniplus-infra/data/witness  # diretório a ser criado pelo time
docker compose up -d
```

Conteúdo de exemplo do `docker-compose.yml` (simplificado):

```yaml
version: '3.8'
networks:
  unifesspa-sim:
    external: true

services:
  etcd-witness:
    image: quay.io/coreos/etcd:v3.5
    container_name: uniplus-witness-etcd
    networks: [unifesspa-sim]
    environment:
      - ETCD_NAME=witness
      - ETCD_INITIAL_ADVERTISE_PEER_URLS=http://172.30.0.10:2380
      - ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380
      - ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
      - ETCD_ADVERTISE_CLIENT_URLS=http://172.30.0.10:2379
    volumes:
      - witness-etcd-data:/etcd-data

  keycloak-master:
    image: quay.io/keycloak/keycloak:25.0
    container_name: uniplus-witness-keycloak
    networks: [unifesspa-sim]
    environment:
      - KEYCLOAK_ADMIN=admin
      - KEYCLOAK_ADMIN_PASSWORD_FILE=/run/secrets/kc_admin
    secrets:
      - kc_admin
    command: start-dev

  minio-master:
    image: minio/minio:latest
    container_name: uniplus-witness-minio
    networks: [unifesspa-sim]
    environment:
      - MINIO_ROOT_USER=admin
      - MINIO_ROOT_PASSWORD_FILE=/run/secrets/minio_admin
    secrets:
      - minio_admin
    command: server /data --console-address ":9001"
    volumes:
      - witness-minio-data:/data

volumes:
  witness-etcd-data:
  witness-minio-data:

secrets:
  kc_admin:
    file: ./secrets/kc_admin.txt
  minio_admin:
    file: ./secrets/minio_admin.txt
```

### 9.3 Conectividade SP1 ↔ Witness

A máquina Ryzen precisa enxergar o etcd witness. Isso é feito **publicando a porta** do witness na máquina i7 e adicionando entrada em `/etc/hosts` da Ryzen:

```bash
# /etc/hosts na Ryzen
192.168.0.20  uniplus-witness  # IP da máquina i7
```

E o `docker-compose.yml` do witness precisa publicar `2379:2379` no host i7.

## 10. Validação final

### 10.1 Validar K3s nos dois clusters

```bash
# SP1
kubectl --context uniplus-sp1 get nodes
kubectl --context uniplus-sp1 get pods -A

# SP2
kubectl --context uniplus-sp2 get nodes
kubectl --context uniplus-sp2 get pods -A
```

### 10.2 Validar componentes do host

```bash
# Em cada máquina
docker compose -f data/postgres/docker-compose.yml ps
docker compose -f data/kafka/docker-compose.yml ps
docker compose -f data/minio/docker-compose.yml ps

# Witness (apenas i7)
docker compose -f data/witness/docker-compose.yml ps
```

### 10.3 Validar Cloudflare Tunnel

```bash
sudo systemctl status cloudflared
curl -v https://uniplus-lab.shop
```

### 10.4 Script automatizado

```bash
./scripts/validate-cluster.sh
```

Este script (em `scripts/`) faz validação completa de todos os componentes.

## 11. Troubleshooting

### K3s não inicia

```bash
# Logs
sudo journalctl -u k3s -f

# Causas comuns
# - Porta 6443 já em uso
# - Firewall bloqueando
# - Erro de DNS (verifique /etc/hosts e systemd-resolved)
```

### Cloudflare Tunnel desconecta

```bash
sudo journalctl -u cloudflared -f

# Causas comuns
# - Credenciais expiradas (refazer login)
# - DNS local resolvendo errado
# - Firewall bloqueando saída para portas 7844/443
```

### Pods em CrashLoopBackOff

```bash
kubectl describe pod <nome> -n <namespace>
kubectl logs <nome> -n <namespace> --previous

# Causas comuns:
# - Recursos insuficientes (verificar requests/limits no values do ambiente)
# - Imagem não encontrada (verificar pull secrets)
# - Volumes não disponíveis
```

### Patroni não consegue eleger primary

```bash
# Verificar quórum etcd
docker exec uniplus-witness-etcd etcdctl member list

# Verificar status do Patroni
docker exec patroni-sp1 patronictl list

# Causas comuns:
# - Witness inacessível (verifique conectividade)
# - Configuração inconsistente entre nós (revisar patroni.yml)
```

### Network unreachable entre SP1 e SP2

```bash
# Da Ryzen
ping -c 4 192.168.0.20
traceroute 192.168.0.20

# Da i7
ping -c 4 192.168.0.10

# Verificar firewall
sudo ufw status
sudo iptables -L -n
```

---

## Anexos

- [VALIDATION-PLAN.md](VALIDATION-PLAN.md) — Cenários de validação a serem executados
- [RUNBOOKS.md](RUNBOOKS.md) — Procedimentos operacionais
- [ARCHITECTURE.md](ARCHITECTURE.md) — Arquitetura completa

---

*Mantido pelo CTIC/UNIFESSPA. Atualizações via Pull Request.*
