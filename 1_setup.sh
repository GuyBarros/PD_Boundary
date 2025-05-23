#import env variables from .env files
export $(grep -v '^#' .env | xargs)

# Run this first to generate PKI keys to use for SSH Access to the target
ssh-keygen -t rsa -b 4096 -N '' -qf ./id_rsa
# if this fails, back up: docker run --rm -it --entrypoint '/keygen.sh ' linuxserver/openssh-server 
# just save the private key as id_rsa and the public key as id_rsa.pub


echo "Starting Boundary Lab"
# Vault
#get the Boundary credentials from Vault
VAULT_LOGIN=$(vault login -method=userpass -format=json username=$VAULT_USER  password=$VAULT_PASSWORD)
VAULT_SECRETS=$(vault kv get -format=json -namespace=admin -mount="kv" "boundary_auth" | jq -r '.data.data')

./configure_vault.sh

export BOUNDARY_AUTH_METHOD=$(echo $VAULT_SECRETS | jq -r '.auth_method')
export BOUNDARY_USERNAME=$(echo $VAULT_SECRETS | jq -r '.username')
export BOUNDARY_PASSWORD=$(echo $VAULT_SECRETS | jq -r '.password')

BOUNDARY_AUTH=$(boundary authenticate password -format json -auth-method-id $BOUNDARY_AUTH_METHOD -login-name $BOUNDARY_USERNAME -password env://BOUNDARY_PASSWORD )

# Manually export Boundary Token if needed
export BOUNDARY_TOKEN=$(echo $BOUNDARY_AUTH | jq -r .item.attributes.token)

echo "Generating Boundary Worker Config"
# Generate Boundary Worker Config
./create_boundary_worker_config.sh

docker compose up -d

export STATIC_HOSTIP=$(docker inspect   -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' boundary-static-target)
export HOSTIP_VAULT=$(docker inspect   -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' boundary-vault-target)

./configure_boundary.sh

echo "Boundary Lab is ready to go!"

# ssh 127.0.0.1 -vvv -p 53350 -o NoHostAuthenticationForLocalhost=yes
# ssh -i id_rsa -i signed.cert sa_pagerduty@localhost -p 2223
# boundary connect -target-id=tssh_gT8Pkdb4J4 -token env://BOUNDARY_TOKEN