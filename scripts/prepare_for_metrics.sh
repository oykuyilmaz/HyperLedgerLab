#!/usr/bin/env bash
#TODO: Get these vaariables from blockchain_setup.yaml
export CHANNEL_NAME="mychannel"
export ORDERER_DOMAIN="orgorderer1"
export CHANNEL_ARTIFACTS_DIR_NAME="channel-artifacts"
export CRYPTO_CONFIG_DIRNAME="crypto-config"
export FABRIC_PEERS_PER_ORG=2 #how to get this?
export ORG_NUMBER=1
export FABRIC_VERSION=2.2.1
export FABRIC_CA_VERSION=1.4.9
export FABRIC_SAMPLES_LINK="https://bit.ly/2ysbOFE"
#export FABRIC_SAMPLES_DIRNAME="fabric-samples"
export CHAINCODE_ID="fabcar"
export CHAINCODE_GO_PATH="fabric-samples/chaincode/fabcar/go"
export CHAINCODE_LABEL="fabcar"
export CHAINCODE_LANGUAGE="golang"
export FABRIC_CFG_PATH="/etc/hyperledger/fabric"
export ORDERER_CA="${FABRIC_CFG_PATH}/${CRYPTO_CONFIG_DIRNAME}/ordererOrganizations/${ORDERER_DOMAIN}/orderers/orderer0.${ORDERER_DOMAIN}/msp/tlscacerts/tlsca.${ORDERER_DOMAIN}-cert.pem"
export NUM_OF_ORG=2;
export SIGNATURE_POLICY="OR('Org1MSP.member','Org2MSP.member')"


run_in_org_cli () {
    kubectl -n "org$1" exec deploy/cli -- bash -c "$2"
}

set +x

#TODO: Assumption org1 always exists
#Create channel in org1
run_in_org_cli 1 "peer channel create -c ${CHANNEL_NAME} --orderer orderer0.${ORDERER_DOMAIN}:7050 --tls --cafile ${ORDERER_CA} -f ./${CHANNEL_ARTIFACTS_DIR_NAME}/${CHANNEL_NAME}.tx"

#Join all peers to the channel in org1
for ((i = 0; i < ${FABRIC_PEERS_PER_ORG}; i++)); do
    run_in_org_cli 1 "CORE_PEER_ADDRESS=peer${i}.org1:7051; peer channel join -b ./${CHANNEL_NAME}.block"
done

#Fetch channel and join all peers in the remaining organizations
for ((i = 2; i <= ${NUM_OF_ORG}; i++)); do
    run_in_org_cli $i "peer channel fetch newest ./${CHANNEL_NAME}.block --orderer orderer0.${ORDERER_DOMAIN}:7050 --tls --cafile ${ORDERER_CA} -c ${CHANNEL_NAME}"
    for ((j = 0; j < ${FABRIC_PEERS_PER_ORG}; j++)); do
        run_in_org_cli $i "CORE_PEER_ADDRESS=peer${j}.org${i}:7051; peer channel join -b ./${CHANNEL_NAME}.block"
    done
done

#Create chaincode, install, and join all peers in the remaining organizations
for ((i = 1; i <= ${NUM_OF_ORG}; i++)); do
    run_in_org_cli ${i} "apk --no-cache add curl"
    run_in_org_cli ${i} "curl -sSL ${FABRIC_SAMPLES_LINK} | bash -s -- ${FABRIC_VERSION} ${FABRIC_CA_VERSION}"
    run_in_org_cli ${i} "peer lifecycle chaincode package ${CHAINCODE_ID}.tar.gz --path ${CHAINCODE_GO_PATH} --lang ${CHAINCODE_LANGUAGE} --label ${CHAINCODE_LABEL}"
    for ((j = 0; j < ${FABRIC_PEERS_PER_ORG}; j++)); do
        run_in_org_cli ${i} "peer lifecycle chaincode install ${CHAINCODE_ID}.tar.gz --peerAddresses peer${j}.org${i}:7051 --tls --tlsRootCertFiles ${FABRIC_CFG_PATH}/${CRYPTO_CONFIG_DIRNAME}/peerOrganizations/org${i}/peers/peer${j}.org${i}/tls/ca.crt"
    done
done

#Approve for the organizations
#TODO: Signature policy update
for ((i = 1; i <= ${NUM_OF_ORG}; i++)); do
    PACKAGE_ID=$(run_in_org_cli ${i} "peer lifecycle chaincode queryinstalled --output json" |jq -r ".installed_chaincodes[0].package_id")
    run_in_org_cli $i "peer lifecycle chaincode approveformyorg -o orderer0.${ORDERER_DOMAIN}:7050 --channelID ${CHANNEL_NAME} --name ${CHAINCODE_ID} --version 1.0 --signature-policy \"${SIGNATURE_POLICY}\" --init-required --package-id ${PACKAGE_ID} --sequence 1 --tls true --cafile ${ORDERER_CA}"
done

ALL_PEERS=""
for ((i = 1; i <= ${NUM_OF_ORG}; i++)); do
    for ((j = 0; j < ${FABRIC_PEERS_PER_ORG}; j++)); do
        ALL_PEERS+="--peerAddresses peer${j}.org${i}:7051 "
    done
    for ((j = 0; j < ${FABRIC_PEERS_PER_ORG}; j++)); do
        ALL_PEERS+="--tlsRootCertFiles ${FABRIC_CFG_PATH}/${CRYPTO_CONFIG_DIRNAME}/peerOrganizations/org${i}/peers/peer${j}.org${i}/tls/ca.crt "
    done
done

#Commit the chaincode at the same time to all peers
run_in_org_cli 1 "peer lifecycle chaincode commit ${ALL_PEERS} --channelID ${CHANNEL_NAME} --name ${CHAINCODE_ID} --version 1.0 --init-required --sequence 1 --signature-policy \"${SIGNATURE_POLICY}\" --tls true --cafile ${ORDERER_CA}"

#Invoke the chaincode since init required is set
run_in_org_cli 1 "peer chaincode invoke --channelID ${CHANNEL_NAME} --name ${CHAINCODE_ID} --tls true --cafile ${ORDERER_CA} --isInit -c '{\"Args\":[\"queryAllCars\"]}'"

set -x