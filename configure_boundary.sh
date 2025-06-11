####################
### DEPLOY BOUNDARY ORGS AND PROJECTS
####################
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
####################
### DEPLOY TARGETS
####################
# echo "Creating Generic TCP Target"
# export LINUX_TCP_TARGET=$(boundary targets create tcp \
#    -name="Linux TCP" \
#    -description="Linux server with tcp and Boundary cred store" \
#    -address=$STATIC_HOSTIP \
#    -default-port=2223 \
#    -scope-id=$PROJECT_ID \
#    -egress-worker-filter='"dockerlab" in "/tags/type"' \
#    -with-alias-value="manual.ssh.target" \
#    -token env://BOUNDARY_TOKEN \
#    -format=json | jq -r '.item.id')

# echo "Creating SHH Target with Credential Injection"
# export LINUX_SSH_TARGET=$(boundary targets create ssh \
#    -name="Linux Cred Injection" \
#    -description="Linux server with SSH Injection and Boundary cred store" \
#    -address=$STATIC_HOSTIP \
#    -default-port=2223 \
#    -scope-id=$PROJECT_ID \
#    -egress-worker-filter='"dockerlab" in "/tags/type"' \
#    -with-alias-value="auto.ssh.target" \
#    -token env://BOUNDARY_TOKEN \
#    -format=json | jq -r '.item.id')

   echo "Creating SHH Target with Vault SSH Injection"
export VAULT_LINUX_SSH_TARGET=$(boundary targets create ssh \
   -name="Vault Linux Cred Injection" \
   -description="Linux server with SSH Injection and Vault cred store" \
   -address=$HOSTIP_VAULT \
   -default-port=2222 \
   -default-client-port=22 \
   -scope-id=$PROJECT_ID \
   -egress-worker-filter='"dockerlab" in "/tags/type"' \
   -with-alias-value="vault.ssh.target" \
   -token env://BOUNDARY_TOKEN \
   -format=json | jq -r '.item.id')


####################
###### DEPLOY CREDENTIAL STORES
####################
# # Static Cred Store
# export BOUNDARY_CRED_STORE_ID=$(boundary credential-stores create static \
# -name="Boundary Static Cred Store" \
#  -scope-id=$PROJECT_ID \
#  -token env://BOUNDARY_TOKEN \
#  -format=json | jq -r '.item.id')

#Vault Cred Store
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
####################
###### Create Credential Library
####################
# export BOUNDARY_CRED_UPW=$(boundary credentials create username-password \
# -name="ssh-user" \
#  -credential-store-id=$BOUNDARY_CRED_STORE_ID \
#  -username=$SSH_USER \
#  -password env://SSH_PASSWORD \
#  -token env://BOUNDARY_TOKEN \
#  -format=json | jq -r '.item.id')

export VAULT_SSH_CRED_LIBRARY=$(boundary credential-libraries create vault-ssh-certificate \
 -name="ssh-vault" \
 -credential-store-id="$BOUNDARY_VAULT_CRED_STORE_ID" \
 -vault-path="ssh/sign/my-role" \
 -username="$SSH_USER" \
 -key-type="ecdsa" \
  -key-bits=521 \
 -token env://BOUNDARY_TOKEN \
 -format=json | jq -r '.item.id')
####################
####### Add Credentials to Target
####################
# export BOUNDARY_CRED_INJECTED=$(boundary targets add-credential-sources \
# -id=$LINUX_SSH_TARGET \
# -injected-application-credential-source=$BOUNDARY_CRED_UPW \
# -token env://BOUNDARY_TOKEN \
# -format=json | jq -r '.item.id')

export BOUNDARY_VAULT_CRED_INJECTED=$(boundary targets add-credential-sources \
  -id=$VAULT_LINUX_SSH_TARGET \
  -injected-application-credential-source=$VAULT_SSH_CRED_LIBRARY \
  -token env://BOUNDARY_TOKEN \
  -format=json | jq -r '.item.id')
