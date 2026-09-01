package bank

import (
	"fmt"
	"math/rand"
	"time"
)

func Seed(seed int64) *Store {
	r := rand.New(rand.NewSource(seed))
	currencies := []string{"BRL", "BRL", "BRL", "USD", "EUR"}
	kinds := []struct{ t, s string }{{"Personal", "CurrentAccount"}, {"Personal", "Savings"}, {"Personal", "CreditCard"}}
	s := &Store{idempotency: map[string]string{}}
	accountNo := 1
	for customer := 1; customer <= 8; customer++ {
		count := 2
		if customer <= 4 {
			count = 3
		}
		for j := 0; j < count; j++ {
			k := kinds[(customer+j)%len(kinds)]
			cur := currencies[(customer+j)%len(currencies)]
			id := fmt.Sprintf("ACC-%03d", accountNo)
			bal := float64(2000+r.Intn(95000)) + float64(r.Intn(100))/100
			if k.s == "CreditCard" {
				bal = -float64(500 + r.Intn(12000))
			}
			a := Account{
				AccountID:      id,
				CustomerID:     fmt.Sprintf("CUS-%03d", customer),
				SchemeName:     "OB.SortCodeAccountNumber",
				Identification: fmt.Sprintf("112800%08d", accountNo),
				Currency:       cur,
				AccountType:    k.t,
				AccountSubType: k.s,
				Nickname:       fmt.Sprintf("%s %02d", k.s, accountNo),
				Status:         "Enabled",
				OpeningDate:    fmt.Sprintf("20%02d-%02d-%02d", 10+r.Intn(15), 1+r.Intn(12), 1+r.Intn(27)),
				Balance:        bal,
			}
			s.Accounts = append(s.Accounts, a)
			txCount := 22 + r.Intn(10)
			for t := 0; t < txCount; t++ {
				debit := r.Intn(100) < 68
				amount := float64(5+r.Intn(4500)) + float64(r.Intn(100))/100
				indicator := "Credit"
				info := "Incoming transfer"
				merchant := ""
				if debit {
					indicator = "Debit"
					vendors := []string{"Mercado Central", "Cloud Telecom", "Energia Sul", "Cafe Paulista", "Metro Transportes", "Farmacia Vida", "Streaming Media", "Air LATAM", "Hotel Centro", "Supermercado Verde"}
					merchant = vendors[r.Intn(len(vendors))]
					info = "Card / account purchase"
				}
				d := time.Now().UTC().Add(-time.Duration(r.Intn(180*24)) * time.Hour).Add(-time.Duration(r.Intn(60)) * time.Minute)
				s.Transactions = append(s.Transactions, Transaction{TransactionID: fmt.Sprintf("TX-%03d-%04d", accountNo, t+1), AccountID: id, Status: "Booked", BookingDateTime: d.Format(time.RFC3339), ValueDateTime: d.Format(time.RFC3339), CreditDebitIndicator: indicator, Amount: Amount{Amount: fmt.Sprintf("%.2f", amount), Currency: cur}, TransactionInformation: info, MerchantName: merchant})
			}
			for b := 0; b < 3; b++ {
				s.Beneficiaries = append(s.Beneficiaries, Beneficiary{BeneficiaryID: fmt.Sprintf("BEN-%03d-%02d", accountNo, b+1), AccountID: id, Name: []string{"Ana Oliveira", "Empresa Solaris Ltda", "Carlos Santos"}[b], SchemeName: "BR.CPF-CNPJ", Identification: fmt.Sprintf("%011d", 10000000000+accountNo*100+b)})
			}
			accountNo++
		}
	}
	return s
}
