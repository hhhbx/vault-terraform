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

# 用环境变量给 Transit seal 提供 token（VAULT_TOKEN），同时也可放 VAULT_LICENSE_PATH
EnvironmentFile=-/etc/vault.d/vault.env

[Install]
WantedBy=multi-user.target
