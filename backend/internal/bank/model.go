package bank

import "time"

type Amount struct {
	Amount   string `json:"Amount"`
	Currency string `json:"Currency"`
}
type Account struct {
	AccountID      string  `json:"AccountId"`
	CustomerID     string  `json:"-"`
	Currency       string  `json:"Currency"`
	AccountType    string  `json:"AccountType"`
	AccountSubType string  `json:"AccountSubType"`
	Nickname       string  `json:"Nickname"`
	Status         string  `json:"Status"`
	OpeningDate    string  `json:"OpeningDate"`
	Balance        float64 `json:"-"`
}
type Transaction struct {
	TransactionID          string `json:"TransactionId"`
	AccountID              string `json:"AccountId"`
	Status                 string `json:"Status"`
	BookingDateTime        string `json:"BookingDateTime"`
	ValueDateTime          string `json:"ValueDateTime"`
	CreditDebitIndicator   string `json:"CreditDebitIndicator"`
	Amount                 Amount `json:"Amount"`
	TransactionInformation string `json:"TransactionInformation"`
	MerchantName           string `json:"MerchantName,omitempty"`
}
type Beneficiary struct {
	BeneficiaryID  string `json:"BeneficiaryId"`
	AccountID      string `json:"AccountId"`
	Name           string `json:"Name"`
	SchemeName     string `json:"SchemeName"`
	Identification string `json:"Identification"`
}
type Payment struct {
	PaymentID            string `json:"DomesticPaymentId"`
	ConsentID            string `json:"ConsentId,omitempty"`
	Status               string `json:"Status"`
	CreationDateTime     string `json:"CreationDateTime"`
	StatusUpdateDateTime string `json:"StatusUpdateDateTime"`
	DebtorAccount        string `json:"DebtorAccount"`
	CreditorName         string `json:"CreditorName"`
	CreditorAccount      string `json:"CreditorAccount"`
	InstructedAmount     Amount `json:"InstructedAmount"`
	Reference            string `json:"Reference"`
}
type PaymentRequest struct {
	ConsentID        string `json:"ConsentId"`
	DebtorAccount    string `json:"DebtorAccount"`
	CreditorName     string `json:"CreditorName"`
	CreditorAccount  string `json:"CreditorAccount"`
	InstructedAmount Amount `json:"InstructedAmount"`
	Reference        string `json:"Reference"`
}
type FundsRequest struct {
	AccountID        string `json:"AccountId"`
	InstructedAmount Amount `json:"InstructedAmount"`
}
type Store struct {
	Accounts      []Account
	Transactions  []Transaction
	Beneficiaries []Beneficiary
	Payments      []Payment
	idempotency   map[string]string
}

func now() string { return time.Now().UTC().Format(time.RFC3339) }
