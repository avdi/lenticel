terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.0"
    }
    bunnynet = {
      source  = "BunnyWay/bunnynet"
      version = "~> 0.13"
    }
  }
}

provider "vultr" {
  api_key = var.vultr_api_key
}

provider "bunnynet" {
  api_key = var.bunny_api_key
}

# ---- Firewall ----

resource "vultr_firewall_group" "lenticel" {
  description = "lenticel"
}

resource "vultr_firewall_rule" "ssh" {
  firewall_group_id = vultr_firewall_group.lenticel.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "22"
  lifecycle { ignore_changes = [source] } # provider v2 always returns source="0.0.0.0/0" from API
}

resource "vultr_firewall_rule" "http" {
  firewall_group_id = vultr_firewall_group.lenticel.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "80"
  lifecycle { ignore_changes = [source] }
}

resource "vultr_firewall_rule" "https" {
  firewall_group_id = vultr_firewall_group.lenticel.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "443"
  lifecycle { ignore_changes = [source] }
}

resource "vultr_firewall_rule" "frps" {
  firewall_group_id = vultr_firewall_group.lenticel.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "7000"
  lifecycle { ignore_changes = [source] }
}

# ---- VPS ----

resource "vultr_instance" "lenticel" {
  plan              = var.vultr_plan
  region            = var.vultr_region
  os_id             = 2284 # Ubuntu 24.04 LTS x64
  label             = "lenticel"
  hostname          = "lenticel"
  ssh_key_ids       = var.vultr_ssh_key_ids
  firewall_group_id = vultr_firewall_group.lenticel.id

  lifecycle {
    ignore_changes = [
      user_data,   # only runs on first boot; VPS is already provisioned
      ssh_key_ids, # changing this destroys the VPS; manage access via authorized_keys
    ]
  }

  user_data = <<-EOF
    #!/bin/bash
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    mkdir -p /opt/lenticel
  EOF
}

# ---- Bunny DNS ----

resource "bunnynet_dns_zone" "lenticel" {
  domain = var.domain
}

resource "bunnynet_dns_record" "apex" {
  zone  = bunnynet_dns_zone.lenticel.id
  name  = ""
  type  = "A"
  value = vultr_instance.lenticel.main_ip
  ttl   = 300
}

resource "bunnynet_dns_record" "wildcard" {
  zone  = bunnynet_dns_zone.lenticel.id
  name  = "*"
  type  = "A"
  value = vultr_instance.lenticel.main_ip
  ttl   = 300
}
