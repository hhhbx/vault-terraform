ui = true

# PoC/VM 场景官方建议 disable_mlock=true
disable_mlock = true

# Enterprise license
license_path = "/etc/vault.d/license.hclic"

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_client_ca_file = "/etc/vault.d/tls/client-ca.crt"
  tls_cert_file = "/etc/vault.d/tls/vault.crt"
  tls_key_file  = "/etc/vault.d/tls/vault.key"
  tls_disable = false
}

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "${node_id}"

%{ for p in peers ~}
  retry_join {
    leader_api_addr        = "https://${p.ip}:8200"
    leader_ca_cert_file    = "/etc/vault.d/tls/ca.crt"
    # 如果你的证书不包含 IP SAN，可能需要 leader_tls_servername（见文末排障）
    %{ if leader_tls_servername != "" ~}
    leader_tls_servername  = "${leader_tls_servername}"
    %{ endif ~}
    # leader_client_cert_file / key_file 仅在你启用了 mTLS 才需要
  }
%{ endfor ~}
}

# Integrated Storage 必须配置 cluster_addr
api_addr     = "https://${node_ip}:8200"
cluster_addr = "https://${node_ip}:8201"

seal "transit" {
  address         = "${transit_address}"
  disable_renewal = "false"
  key_name        = "${transit_key_name}"
  mount_path      = "${transit_mount_path}"
  tls_skip_verify = ${transit_tls_skip_verify}
  # token 不写这里：用 systemd EnvironmentFile 里的 VAULT_TOKEN（官方推荐）
}
