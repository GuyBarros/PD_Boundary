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
  --name=boundary-target \
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

export HOSTIP=$(docker inspect   -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' boundary-target)

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
   -description="Linux server with tcp" \
   -address=$HOSTIP \
   -default-port=2222 \
   -scope-id=$PROJECT_ID \
   -egress-worker-filter='"dockerlab" in "/tags/type"' \
   -with-alias-value="manual.ssh.target" \
   -token env://BOUNDARY_TOKEN \
   -format=json | jq -r '.item.id')

echo "Creating SHH Target with Credential Injection"
export LINUX_SSH_TARGET=$(boundary targets create ssh \
   -name="Linux Cred Injection" \
   -description="Linux server with SSH Injection" \
   -address=$HOSTIP \
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
boundary targets add-credential-sources \
-id=$LINUX_SSH_TARGET \
-injected-application-credential-source=$BOUNDARY_CRED_UPW \
-token env://BOUNDARY_TOKEN 

echo "Boundary Lab is ready to go!"