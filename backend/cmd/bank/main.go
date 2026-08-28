package main

import (
	"example.com/wso2-openbanking-demo/backend/internal/bank"
	"log"
	"net/http"
	"os"
	"strconv"
)

func main() {
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	seed := int64(20260827)
	if s := os.Getenv("SEED"); s != "" {
		if v, e := strconv.ParseInt(s, 10, 64); e == nil {
			seed = v
		}
	}
	store := bank.Seed(seed)
	api := bank.NewAPI(store)
	log.Printf("mock bank listening on %s with %d accounts and %d transactions", addr, len(store.Accounts), len(store.Transactions))
	log.Fatal(http.ListenAndServe(addr, api.Handler()))
}
