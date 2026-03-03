locals {
  nodes_by_name = { for n in var.nodes : n.name => n }

  # 如果你的证书 SAN 不包含 IP，可以把这里改成证书里存在的 DNS 名（比如 "vault-api"）
  # 否则保持空字符串
  leader_tls_servername = ""

  leader_tls_line = local.leader_tls_servername != "" ? "    leader_tls_servername = \"${local.leader_tls_servername}\"\n" : ""

  retry_join_blocks = join("\n", [
    for p in var.nodes :
    format(
      "  retry_join {\n    leader_api_addr     = \"https://%s:8200\"\n    leader_ca_cert_file = \"/etc/vault.d/tls/ca.crt\"\n%s  }\n",
      p.ip,
      local.leader_tls_line
    )
  ])

  # ✅ server.hcl（包含：raft 数据路径 + 日志文件位置）
  server_hcl_template = <<-HCL
ui = true
disable_mlock = true

license_path = "/etc/vault.d/license.hclic"

# ✅ operational log 落盘（官方参数）
log_level = "info"
log_file  = "/var/log/vault/vault.log"
log_rotate_duration  = "24h"
log_rotate_bytes     = 104857600
log_rotate_max_files = 10

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/etc/vault.d/tls/vault.crt"
  tls_key_file    = "/etc/vault.d/tls/vault.key"
}

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "__NODE_ID__"

__RETRY_JOIN__
}

api_addr     = "https://__NODE_IP__:8200"
cluster_addr = "https://__NODE_IP__:8201"

seal "transit" {
  address         = "${var.transit_address}"
  disable_renewal = "false"
  key_name        = "${var.transit_key_name}"
  mount_path      = "${var.transit_mount_path}"
  tls_skip_verify = ${var.transit_tls_skip_verify}
  # token 不写这里：systemd 通过 /etc/vault.d/vault.env 注入 VAULT_TOKEN
}
HCL

  vault_service_unit = <<-UNIT
[Unit]
Description=HashiCorp Vault
After=network-online.target
Wants=network-online.target

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/server.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitMEMLOCK=infinity
CapabilityBoundingSet=CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK

EnvironmentFile=-/etc/vault.d/vault.env

[Install]
WantedBy=multi-user.target
UNIT
}

resource "null_resource" "vault_node" {
  for_each = local.nodes_by_name

  # ✅ 关键：把 SSH 连接信息固化到 triggers（destroy 阶段 connection 只能引用 self）
  triggers = {
    ssh_host     = each.value.ip
    ssh_user     = var.ssh_user
    ssh_password = var.ssh_password

    # 这些确保模板/参数变化会触发重跑
    server_hcl_sha   = sha256(local.server_hcl_template)
    service_unit_sha = sha256(local.vault_service_unit)

    vault_version   = var.vault_version
    transit_address = var.transit_address
    transit_key     = var.transit_key_name
    transit_mount   = var.transit_mount_path
    transit_skip    = tostring(var.transit_tls_skip_verify)

    #ca_sha  = filesha256("${var.local_config_dir}/root-ca.crt")
    #crt_sha = filesha256("${var.local_config_dir}/vault-api.crt")
    #key_sha = filesha256("${var.local_config_dir}/vault-api.pem")
    #lic_sha = filesha256("${var.local_config_dir}/vault.hclic")
    #env_sha = filesha256("${var.local_config_dir}/vault.env")
      
    ca_sha  = filesha256("/home/config/root-ca.crt")
    crt_sha = filesha256("/home/config/vault-api.crt")
    key_sha = filesha256("/home/config/vault-api.pem")
    lic_sha = filesha256("/home/config/vault.hclic")
    env_sha = filesha256("/home/config/vault.env")
}

  connection {
    type     = "ssh"
    host     = self.triggers["ssh_host"]
    user     = self.triggers["ssh_user"]
    password = self.triggers["ssh_password"]
    timeout  = "60s"
  }

  # 0) 目录准备
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "mkdir -p /etc/vault.d/tls /opt/vault/data /var/log/vault",
    ]
  }

  # 1) 上传证书 / license / env
  provisioner "file" {
    source      = "${var.local_config_dir}/root-ca.crt"
    destination = "/etc/vault.d/tls/ca.crt"
  }

  provisioner "file" {
    source      = "${var.local_config_dir}/vault-api.crt"
    destination = "/etc/vault.d/tls/vault.crt"
  }

  provisioner "file" {
    source      = "${var.local_config_dir}/vault-api.pem"
    destination = "/etc/vault.d/tls/vault.key"
  }

  provisioner "file" {
    source      = "${var.local_config_dir}/vault.hclic"
    destination = "/etc/vault.d/license.hclic"
  }

  provisioner "file" {
    source      = "${var.local_config_dir}/vault.env"
    destination = "/etc/vault.d/vault.env"
  }

  # 2) 安装 Vault + 用户组 + 写 server.hcl + systemd + 权限 + 启动
  provisioner "remote-exec" {
    inline = [
      "set -e",

      # 依赖
      "if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl unzip jq ca-certificates; fi",
      "if command -v yum >/dev/null 2>&1; then yum install -y curl unzip jq ca-certificates; fi",
      "if command -v dnf >/dev/null 2>&1; then dnf install -y curl unzip jq ca-certificates; fi",

      # 安装 Vault：优先 ent 包，失败回退 oss 包
      "if ! command -v vault >/dev/null 2>&1; then ENT_URL=\"https://releases.hashicorp.com/vault/${var.vault_version}+ent/vault_${var.vault_version}+ent_linux_amd64.zip\"; OSS_URL=\"https://releases.hashicorp.com/vault/${var.vault_version}/vault_${var.vault_version}_linux_amd64.zip\"; rm -f /tmp/vault.zip; (curl -fsSL -o /tmp/vault.zip \"$ENT_URL\" || curl -fsSL -o /tmp/vault.zip \"$OSS_URL\"); unzip -o /tmp/vault.zip -d /tmp; install -m 0755 /tmp/vault /usr/local/bin/vault; fi",

      # vault 用户/组（幂等）
      "getent group vault >/dev/null 2>&1 || groupadd --system vault",
      "id vault >/dev/null 2>&1 || (NOLOGIN=$(command -v nologin || echo /sbin/nologin); useradd --system --home /etc/vault.d --shell \"$NOLOGIN\" -g vault vault)",

      # 写 server.hcl（base64 方式避免 heredoc 解析坑）
      format(
        "printf '%%s' '%s' | base64 -d > /etc/vault.d/server.hcl",
        base64encode(
          replace(
            replace(
              replace(local.server_hcl_template, "__NODE_ID__", each.key),
              "__NODE_IP__", self.triggers["ssh_host"]
            ),
            "__RETRY_JOIN__", local.retry_join_blocks
          )
        )
      ),

      # 写 systemd unit
      format(
        "printf '%%s' '%s' | base64 -d > /etc/systemd/system/vault.service",
        base64encode(local.vault_service_unit)
      ),

      # ✅ 权限：配置 root 管，数据/日志 vault 可写（避免 raft vault.db permission denied）
      "chown -R root:vault /etc/vault.d /etc/vault.d/tls",
      "chmod 750 /etc/vault.d /etc/vault.d/tls",

      "chown -R vault:vault /opt/vault /opt/vault/data /var/log/vault",
      "chmod 750 /opt/vault /opt/vault/data /var/log/vault",

      # 日志文件确保可写
      "touch /var/log/vault/vault.log || true",
      "chown vault:vault /var/log/vault/vault.log || true",
      "chmod 640 /var/log/vault/vault.log || true",

      "chmod 644 /etc/vault.d/tls/ca.crt /etc/vault.d/tls/vault.crt /etc/vault.d/license.hclic",
      "chmod 640 /etc/vault.d/tls/vault.key /etc/vault.d/server.hcl /etc/vault.d/vault.env",

      # 启动
      "systemctl daemon-reload",
      "systemctl enable vault",
      "systemctl reset-failed vault || true",
      "systemctl restart vault",
      "sleep 1",
      "systemctl --no-pager status vault | sed -n '1,14p' || true",
      "ss -lntp | egrep ':8200|:8201' || true",
    ]
  }

  # ✅ destroy 清理（注意：connection 已经只引用 self，所以不会再报错）
  provisioner "remote-exec" {
    when = destroy
    inline = [
      "set -e",
      "systemctl stop vault || true",
      "systemctl disable vault || true",
      "systemctl reset-failed vault || true",

      "rm -f /etc/systemd/system/vault.service || true",
      "systemctl daemon-reload || true",

      "rm -f /root/vault-init.json || true",
      "rm -rf /etc/vault.d || true",
      "rm -rf /opt/vault || true",
      "rm -rf /var/log/vault || true",

      # PoC 清理更彻底（可按需注释掉）
      "rm -f /usr/local/bin/vault || true",
      "userdel vault || true",
      "groupdel vault || true",
    ]
  }
}

# 只在 nodes[0] 做 init（这里不加 destroy provisioner，避免 destroy 限制）
resource "null_resource" "vault_init" {
  depends_on = [null_resource.vault_node]

  connection {
    type     = "ssh"
    host     = var.nodes[0].ip
    user     = var.ssh_user
    password = var.ssh_password
    timeout  = "60s"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "export VAULT_ADDR=https://${var.nodes[0].ip}:8200",
      "export VAULT_CACERT=/etc/vault.d/tls/ca.crt",

      "for i in $(seq 1 60); do curl -sk --cacert $VAULT_CACERT $VAULT_ADDR/v1/sys/health >/dev/null 2>&1 && break || true; sleep 1; done",
      "if vault status -format=json 2>/dev/null | jq -e '.initialized==true' >/dev/null 2>&1; then echo '[init] already initialized'; exit 0; fi",

      "vault operator init -format=json > /root/vault-init.json",
      "chmod 600 /root/vault-init.json",
      "echo '[init] saved to /root/vault-init.json'",

      "for i in $(seq 1 60); do sealed=$(vault status -format=json | jq -r '.sealed'); [ \"$sealed\" = \"false\" ] && break || true; sleep 1; done",
      "vault status || true",

      "export VAULT_TOKEN=$(jq -r '.root_token' /root/vault-init.json)",
      "echo '[raft] list-peers:'",
      "vault operator raft list-peers || true",
    ]
  }
}
