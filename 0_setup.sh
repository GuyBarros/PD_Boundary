#import env variables from .env files
export $(grep -v '^#' .env | xargs)

echo "Starting Boundary Lab"
#get the Boundary credentials from Vault
VAULT_LOGIN=$(vault login -method=userpass -format=json username=$VAULT_USER  password=$VAULT_PASSWORD)

VAULT_SECRETS=$(vault kv get -format=json -namespace=admin -mount="kv" "boundary_auth" | jq -r '.data.data')

export BOUNDARY_AUTH_METHOD=$(echo $VAULT_SECRETS | jq -r '.auth_method')
export BOUNDARY_USERNAME=$(echo $VAULT_SECRETS | jq -r '.username')
export BOUNDARY_PASSWORD=$(echo $VAULT_SECRETS | jq -r '.password')

BOUNDARY_AUTH=$(boundary authenticate password -format json -auth-method-id $BOUNDARY_AUTH_METHOD -login-name $BOUNDARY_USERNAME -password env://BOUNDARY_PASSWORD )

# Manually export Boundary Token if needed
export BOUNDARY_TOKEN=$(echo $BOUNDARY_AUTH | jq -r .item.attributes.token)

echo "Generating Boundary Worker Config"
# Generate Boundary Worker Config
./create_boundary_config.sh

echo "Starting Boundary Worker"
# Boundary Worker
docker run -d \
  --name=boundary-worker \
  -p 9202:9202 \
  -v "$(pwd)":/boundary/ \
  hashicorp/boundary-enterprise:latest

# Boundary Worker up and running

# Run this first to generate PKI keys to use for SSH Access to the target
ssh-keygen -t rsa -b 4096 -N '' -qf ./id_rsa
# if this fails, back up: docker run --rm -it --entrypoint '/keygen.sh ' linuxserver/openssh-server 
# just save the private key as id_rsa and the public key as id_rsa.pub


echo "Creating SSH Target"
# Boundary Target
docker run -d \
  --name=boundary-static-target \
  --hostname=demo-server \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  -e PASSWORD_ACCESS=true \
  -e PUBLIC_KEY_FILE=./id_rsa.pub \
  -e USER_PASSWORD=$SSH_PASSWORD \
  -e USER_NAME=$SSH_USER  \
  -e SUDO_ACCESS=false \
  -p 2222:2222 \
  --restart unless-stopped \
  lscr.io/linuxserver/openssh-server:latest

export STATIC_HOSTIP=$(docker inspect   -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' boundary-static-target)

####################
### DEPLOY BOUNDARY ORGS AND PROJECTS
echo "Creating Boundary Organization"

export ORG_ID=$(boundary scopes create \
 -scope-id=global -name="Docker Lab" \
 -description="Docker Org" \
 -token env://BOUNDARY_TOKEN \
 -format=json | jq -r '.item.id')

echo "Creating Boundary Project"
export PROJECT_ID=$(boundary scopes create \
 -scope-id=$ORG_ID -name="Docker Servers" \
 -description="Server Machines" \
 -token env://BOUNDARY_TOKEN \
 -format=json | jq -r '.item.id')

### DEPLOY TARGETS
echo "Creating Generic TCP Target"
export LINUX_TCP_TARGET=$(boundary targets create tcp \
   -name="Linux TCP" \
   -description="Linux server with tcp and Boundary cred store" \
   -address=$STATIC_HOSTIP \
   -default-port=2222 \
   -scope-id=$PROJECT_ID \
   -egress-worker-filter='"dockerlab" in "/tags/type"' \
   -with-alias-value="manual.ssh.target" \
   -token env://BOUNDARY_TOKEN \
   -format=json | jq -r '.item.id')

echo "Creating SHH Target with Credential Injection"
export LINUX_SSH_TARGET=$(boundary targets create ssh \
   -name="Linux Cred Injection" \
   -description="Linux server with SSH Injection and Boundary cred store" \
   -address=$STATIC_HOSTIP \
   -default-port=2222 \
   -scope-id=$PROJECT_ID \
   -egress-worker-filter='"dockerlab" in "/tags/type"' \
   -with-alias-value="auto.ssh.target" \
   -token env://BOUNDARY_TOKEN \
   -format=json | jq -r '.item.id')

### DEPLOY CREDENTIAL STORE AND LIBRARY
export BOUNDARY_CRED_STORE_ID=$(boundary credential-stores create static \
-name="Boundary Static Cred Store" \
 -scope-id=$PROJECT_ID \
 -token env://BOUNDARY_TOKEN \
 -format=json | jq -r '.item.id')

export BOUNDARY_CRED_UPW=$(boundary credentials create username-password \
-name="ssh-user" \
 -credential-store-id=$BOUNDARY_CRED_STORE_ID \
 -username=$SSH_USER \
 -password env://SSH_PASSWORD \
 -token env://BOUNDARY_TOKEN \
 -format=json | jq -r '.item.id')

### ADD CREDENTIALS
export BOUNDARY_CRED_INJECTED=$(boundary targets add-credential-sources \
-id=$LINUX_SSH_TARGET \
-injected-application-credential-source=$BOUNDARY_CRED_UPW \
-token env://BOUNDARY_TOKEN \
-format=json | jq -r '.item.id')

### ADD Configure Vault
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

# Create a token with the superuser policy
export VAULT_CRED_STORE_TOKEN=$(vault token create -policy=superuser_$(date +%Y%m%d) -format=json -orphan -period=72h -display-name="boundary_cred_store_$(date +%Y%m%d)" | jq -r .auth.client_token)

export BOUNDARY_VAULT_CRED_STORE_ID=$(boundary credential-stores create vault \
-name="Boundary Vault Cred Store" \
 -scope-id=$PROJECT_ID \
  -vault-address=$VAULT_ADDR \
  -vault-token=$VAULT_CRED_STORE_TOKEN \
  -vault-namespace=$VAULT_NAMESPACE \
 -token env://BOUNDARY_TOKEN \
 -format=json | jq -r '.item.id')

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
cat etc/ssh/sshd_config
cat /etc/ssh/ca-key.pub
EOF


vault write ssh/roles/my-role -<<EOH
{
  "algorithm_signer": "rsa-sha2-256",
  "allow_user_certificates": true,
  "allowed_users": "*",
  "allowed_extensions": "permit-pty,permit-port-forwarding",
  "default_extensions": {
    "permit-pty": ""
  },
  "key_type": "ca",
  "default_user": "$SSH_USER"
}
EOH

export VAULT_SSH_CRED_LIBRARY=$(boundary credential-libraries create vault-ssh-certificate \
 -name="ssh-vault" \
 -credential-store-id="$BOUNDARY_VAULT_CRED_STORE_ID" \
 -vault-path="ssh/sign/my-role" \
 -username="$SSH_USER" \
 -key-type="rsa" \
 -token env://BOUNDARY_TOKEN \
 -format=json | jq -r '.item.id')


echo "Creating SSH Target"
# Startign Boundary Target
docker run -d \
  --name=boundary-vault-target \
  --hostname=demo-vault-server \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  -e PASSWORD_ACCESS=true \
  -e USER_PASSWORD=$SSH_PASSWORD \
  -e USER_NAME=$SSH_USER  \
  -e SUDO_ACCESS=false \
  -v "$(pwd)/ca":/ca \
  -v "$(pwd)/custom-cont-init.d":/custom-cont-init.d \
  -p 2223:2222 \
  --restart unless-stopped \
  lscr.io/linuxserver/openssh-server:latest

export HOSTIP_VAULT=$(docker inspect   -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' boundary-vault-target)

#create a new target 
echo "Creating SHH Target with Credential Injection"
export VAULT_LINUX_SSH_TARGET=$(boundary targets create ssh \
   -name="Vault Linux Cred Injection" \
   -description="Linux server with SSH Injection and Vault cred store" \
   -address=$HOSTIP_VAULT \
   -default-port=2223 \
   -scope-id=$PROJECT_ID \
   -egress-worker-filter='"dockerlab" in "/tags/type"' \
   -with-alias-value="vault.ssh.target" \
   -token env://BOUNDARY_TOKEN \
   -format=json | jq -r '.item.id')

export BOUNDARY_VAULT_CRED_INJECTED=$(boundary targets add-credential-sources \
  -id=$VAULT_LINUX_SSH_TARGET \
  -injected-application-credential-source=$VAULT_SSH_CRED_LIBRARY \
  -token env://BOUNDARY_TOKEN \
  -format=json | jq -r '.item.id')

echo "Boundary Lab is ready to go!"

export BOUNDARY_VAULT_CRED_STORE_ID=csvlt_oXjUqirsuu