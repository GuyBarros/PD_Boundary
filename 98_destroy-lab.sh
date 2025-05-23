#import env variables from .env files
export $(grep -v '^#' .env | xargs)

echo "Deleting Boundary Lab"
#get the Boundary credentials from Vault
VAULT_LOGIN=$(vault login -method=userpass -format=json username=$VAULT_USER  password=$VAULT_PASSWORD)

VAULT_SECRETS=$(vault kv get -format=json -namespace=admin -mount="kv" "boundary_auth" | jq -r '.data.data')

export BOUNDARY_AUTH_METHOD=$(echo $VAULT_SECRETS | jq -r '.auth_method')
export BOUNDARY_USERNAME=$(echo $VAULT_SECRETS | jq -r '.username')
export BOUNDARY_PASSWORD=$(echo $VAULT_SECRETS | jq -r '.password')

BOUNDARY_AUTH=$(boundary authenticate password -format json -auth-method-id $BOUNDARY_AUTH_METHOD -login-name $BOUNDARY_USERNAME -password env://BOUNDARY_PASSWORD )

# Manually export Boundary Token if needed
export BOUNDARY_TOKEN=$(echo $BOUNDARY_AUTH | jq -r .item.attributes.token)

#######################################################
#### to Destroy everything 
export ORG_ID_DEL=$(boundary scopes list -format=json -token env://BOUNDARY_TOKEN | jq -r '.items[] | select(.name == "Docker Lab") | .id')
export WORKER_DEL=$(boundary workers list -format=json -token env://BOUNDARY_TOKEN | jq -r '.items[] | select(.name | contains("docker")) | .id')

  # Get all aliases for the target
  alias_ids=$(boundary  aliases list -format=json -token env://BOUNDARY_TOKEN | jq -r '.items[].id')

  for alias_id in $alias_ids; do
    echo "  Deleting Alias ID: $alias_id for Target ID: $target_id"
    boundary aliases delete  -id "$alias_id" -token env://BOUNDARY_TOKEN
  done


boundary scopes delete -id=$ORG_ID_DEL
for WORKER in $WORKER_DEL; do
    boundary workers delete -id $WORKER -token env://BOUNDARY_TOKEN  
    echo "Deleted worker: $WORKER"
done


rm -rf ./file
rm -rf ./recording
rm -rf ./ca
rm -rf ./custom-cont-init.d
rm id_rsa id_rsa.pub config.hcl trusted-user-ca-keys.pem

vault policy delete superuser_$(date +%Y%m%d)
vault secrets disable ssh

docker compose down
