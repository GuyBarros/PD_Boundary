#######################################################
#### to Destroy everything 
export ORG_ID_DEL=$(boundary scopes list -format=json -token env://BOUNDARY_TOKEN | jq -r '.items[] | select(.name == "Docker Lab") | .id')
export WORKER_DEL=$(boundary workers list -format=json -token env://BOUNDARY_TOKEN | jq -r '.items[] | select(.name | contains("docker")) | .id')


boundary scopes delete -id=$ORG_ID_DEL
for WORKER in $WORKER_DEL; do
    boundary workers delete -id $WORKER -token env://BOUNDARY_TOKEN  
    echo "Deleted worker: $WORKER"
done

docker stop boundary-target
docker rm boundary-target

docker stop boundary-worker
docker rm boundary-worker

rm -rf ./file
rm -rf ./recording
rm id_rsa id_rsa.pub config.hcl

#optional
# rm id_rsa id_rsa.pub config.hcl