# Mount SSH secrets engine
vault secrets enable -path=ssh ssh

mkdir ca/ && mkdir custom-cont-init.d/

vault write -format=json ssh/config/ca generate_signing_key=true | \
    jq -r '.data.public_key' > ca/ca-key.pub

cat > custom-cont-init.d/00-trust-user-ca -<<EOF
#!/usr/bin/with-contenv bash

cp /ca/ca-key.pub /etc/ssh/ca-key.pub
chown 1000:1000 /etc/ssh/ca-key.pub
chmod 644 /etc/ssh/ca-key.pub
echo TrustedUserCAKeys /etc/ssh/ca-key.pub >> /etc/ssh/sshd_config
echo PermitTTY yes >> /etc/ssh/sshd_config
sed -i 's/X11Forwarding no/X11Forwarding yes/' /etc/ssh/sshd_config
echo "X11UseLocalhost no" >> /etc/ssh/sshd_config

apk update
apk add xterm util-linux dbus ttf-freefont xauth firefox
EOF


vault write ssh/roles/my-role -<<EOH
{
    "key_type": "ca",
    "allow_user_certificates": true,
    "default_user": "$SSH_USER",
    "default_extensions": {
        "permit-pty": ""
    },
    "allowed_users": "*",
    "allowed_extensions": "*"
}
EOH
### Add Configure Vault
echo "Configuring Vault for secret store"
echo "--> configure superuser role"


vault policy write superuser_$(date +%Y%m%d) - <<EOR
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
  }

  path "kv/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "kv/test/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "ssh/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "pki/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "sys/control-group/authorize" {
    capabilities = ["create", "update"]
}

# To check control group request status
path "sys/control-group/request" {
    capabilities = ["create", "update"]
}

# all access to boundary namespace
path "boundary/*" {
    capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOR