variable "nodes" {
  type = list(object({
    name = string
    ip   = string
  }))
  default = [
    { name = "vault-node1", ip = "192.168.56.120" },
    { name = "vault-node2", ip = "192.168.56.121" },
    { name = "vault-node3", ip = "192.168.56.122" },
  ]
}

variable "ssh_user" {
  type    = string
  default = "root"
}

variable "ssh_password" {
  type      = string
  sensitive = true
}

# 你本地证书/License目录（WSL路径） default = "/mnt/f/01_Project/01-Vault/MAS/config"
variable "local_config_dir" {
  type    = string
  default = "/home/config"
}

# Vault 版本（可改）
variable "vault_version" {
  type    = string
  default = "1.21.3+ent"
}

# Transit seal 配置（token 不写在这里，走环境变量 VAULT_TOKEN）
variable "transit_address" {
  type    = string
  default = "http://14.103.137.133:8200"
}

variable "transit_key_name" {
  type    = string
  default = "autounseal"
}

variable "transit_mount_path" {
  type    = string
  default = "transit/"
}

variable "transit_tls_skip_verify" {
  type    = bool
  default = true
}
