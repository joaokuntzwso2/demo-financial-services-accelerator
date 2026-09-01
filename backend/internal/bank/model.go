package bank

import (
	"encoding/json"
	"time"
)

type Amount struct {
	Amount   string `json:"Amount"`
	Currency string `json:"Currency"`
}
type Account struct {
	AccountID      string  `json:"AccountId"`
	CustomerID     string  `json:"-"`
	SchemeName     string  `json:"SchemeName"`
	Identification string  `json:"Identification"`
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
	PaymentID                 string `json:"DomesticPaymentId"`
	ConsentID                 string `json:"ConsentId,omitempty"`
	Status                    string `json:"Status"`
	CreationDateTime          string `json:"CreationDateTime"`
	StatusUpdateDateTime      string `json:"StatusUpdateDateTime"`
	InstructionIdentification string `json:"InstructionIdentification,omitempty"`
	EndToEndIdentification    string `json:"EndToEndIdentification,omitempty"`
	DebtorAccount             string `json:"DebtorAccount"`
	CreditorName              string `json:"CreditorName"`
	CreditorAccount           string `json:"CreditorAccount"`
	InstructedAmount          Amount `json:"InstructedAmount"`
	Reference                 string `json:"Reference"`
}

type PaymentRequest struct {
	ConsentID                 string `json:"ConsentId"`
	InstructionIdentification string `json:"InstructionIdentification"`
	EndToEndIdentification    string `json:"EndToEndIdentification"`
	DebtorAccount             string `json:"DebtorAccount"`
	CreditorName              string `json:"CreditorName"`
	CreditorAccount           string `json:"CreditorAccount"`
	InstructedAmount          Amount `json:"InstructedAmount"`
	Reference                 string `json:"Reference"`
}

// PaymentAccountReference is the account representation used by the
// Financial Services Accelerator payment initiation contract.
type PaymentAccountReference struct {
	SchemeName     string `json:"SchemeName"`
	Identification string `json:"Identification"`
	Name           string `json:"Name,omitempty"`
}

// PaymentRemittanceInformation contains the payment reference data authorised
// by the PSU as part of the consent.
type PaymentRemittanceInformation struct {
	Reference    string `json:"Reference,omitempty"`
	Unstructured string `json:"Unstructured,omitempty"`
}

// PaymentInitiation is the Open Banking payment instruction persisted in the
// Financial Services consent receipt and submitted again when creating the
// payment.
type PaymentInitiation struct {
	InstructionIdentification string                       `json:"InstructionIdentification"`
	EndToEndIdentification    string                       `json:"EndToEndIdentification"`
	LocalInstrument           string                       `json:"LocalInstrument,omitempty"`
	InstructedAmount          Amount                       `json:"InstructedAmount"`
	DebtorAccount             PaymentAccountReference      `json:"DebtorAccount"`
	CreditorAccount           PaymentAccountReference      `json:"CreditorAccount"`
	RemittanceInformation     PaymentRemittanceInformation `json:"RemittanceInformation,omitempty"`
}

// PaymentSubmissionData is the WSO2 Financial Services payment submission
// envelope.
type PaymentSubmissionData struct {
	ConsentID  string            `json:"ConsentId"`
	Initiation PaymentInitiation `json:"Initiation"`
}

// PaymentSubmission is the Gateway-facing payment request shape validated by
// the Financial Services Accelerator.
type PaymentSubmission struct {
	Data PaymentSubmissionData `json:"Data"`
	Risk map[string]any        `json:"Risk,omitempty"`
}

// UnmarshalJSON accepts the Financial Services/Open Banking submission shape
// and converts it into the bank's internal PaymentRequest command.
//
// The legacy flat form remains decodable for internal unit tests and direct
// backend compatibility. It cannot bypass the external Gateway contract:
// WSO2 Consent Enforcement rejects that shape before forwarding the request.
func (p *PaymentRequest) UnmarshalJSON(data []byte) error {
	var probe struct {
		Data json.RawMessage `json:"Data"`
	}

	if err := json.Unmarshal(data, &probe); err != nil {
		return err
	}

	if len(probe.Data) > 0 && string(probe.Data) != "null" {
		var submission PaymentSubmission

		if err := json.Unmarshal(data, &submission); err != nil {
			return err
		}

		initiation := submission.Data.Initiation

		*p = PaymentRequest{
			ConsentID:                 submission.Data.ConsentID,
			InstructionIdentification: initiation.InstructionIdentification,
			EndToEndIdentification:    initiation.EndToEndIdentification,
			DebtorAccount:             initiation.DebtorAccount.Identification,
			CreditorName:              initiation.CreditorAccount.Name,
			CreditorAccount:           initiation.CreditorAccount.Identification,
			InstructedAmount:          initiation.InstructedAmount,
			Reference:                 initiation.RemittanceInformation.Reference,
		}

		return nil
	}

	type plainPaymentRequest PaymentRequest

	var legacy plainPaymentRequest

	if err := json.Unmarshal(data, &legacy); err != nil {
		return err
	}

	*p = PaymentRequest(legacy)

	return nil
}

type FundsRequest struct {
	ConsentID        string `json:"ConsentId"`
	Reference        string `json:"Reference"`
	AccountID        string `json:"AccountId,omitempty"`
	InstructedAmount Amount `json:"InstructedAmount"`

	// structured is true for the standards-facing
	// OBFundsConfirmation1 Data envelope.
	structured bool
}

type FundsSubmissionData struct {
	ConsentID        string `json:"ConsentId"`
	Reference        string `json:"Reference"`
	InstructedAmount Amount `json:"InstructedAmount"`
}

type FundsSubmission struct {
	Data FundsSubmissionData `json:"Data"`
}

func (f *FundsRequest) UnmarshalJSON(data []byte) error {
	var probe struct {
		Data *FundsSubmissionData `json:"Data"`
	}

	if err := json.Unmarshal(data, &probe); err != nil {
		return err
	}

	if probe.Data != nil {
		*f = FundsRequest{
			ConsentID:        probe.Data.ConsentID,
			Reference:        probe.Data.Reference,
			InstructedAmount: probe.Data.InstructedAmount,
			structured:       true,
		}

		return nil
	}

	// Retain the old flat form only for direct/internal test
	// compatibility. The Gateway-facing OpenAPI contract uses
	// Data.ConsentId + Data.Reference + Data.InstructedAmount.
	type plainFundsRequest FundsRequest

	var legacy plainFundsRequest

	if err := json.Unmarshal(data, &legacy); err != nil {
		return err
	}

	*f = FundsRequest(legacy)

	return nil
}

type Store struct {
	Accounts      []Account
	Transactions  []Transaction
	Beneficiaries []Beneficiary
	Payments      []Payment
	idempotency   map[string]string
}

func now() string { return time.Now().UTC().Format(time.RFC3339) }
