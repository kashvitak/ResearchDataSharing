package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&ResearchContract{})
	if err != nil {
		log.Panicf("error creating chaincode: %v", err)
	}
	if err := cc.Start(); err != nil {
		log.Panicf("error starting chaincode: %v", err)
	}
}
