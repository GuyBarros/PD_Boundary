#!/bin/bash
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

# Configuration Variables
export TARGET_ALIAS="auto.ssh.target"

# Start Boundary proxy in the background using coproc
coproc BOUNDARY_PROXY ( boundary connect -target-id $TARGET_ALIAS -token env://BOUNDARY_TOKEN -format json )

# Read the Boundary proxy information (address, port, session_id)
read -r -u ${BOUNDARY_PROXY[0]} BOUNDARY_PROXY_INFO

# Parse the JSON to get the proxy address, port, and session ID using jq
BOUNDARY_PROXY_ADDR=$(echo $BOUNDARY_PROXY_INFO | jq -r '.address')
BOUNDARY_PROXY_PORT=$(echo $BOUNDARY_PROXY_INFO | jq -r '.port')
BOUNDARY_SESSION_ID=$(echo $BOUNDARY_PROXY_INFO | jq -r '.session_id')

# Output proxy information for debugging
echo "Boundary proxy is running on ${BOUNDARY_PROXY_ADDR}:${BOUNDARY_PROXY_PORT}"
echo "Boundary process ID is ${BOUNDARY_PROXY_PID}"

# Establish SSH tunnel via the Boundary proxy
ssh -p $BOUNDARY_PROXY_PORT $BOUNDARY_PROXY_ADDR -4 -f -NL  -o StrictHostKeyChecking=no


boundary sessions cancel -id $BOUNDARY_SESSION_ID -token env://BOUNDARY_TOKEN

# Terminate the Boundary proxy process
kill -INT $BOUNDARY_PROXY_PID

echo "Session and Proxy terminated."






