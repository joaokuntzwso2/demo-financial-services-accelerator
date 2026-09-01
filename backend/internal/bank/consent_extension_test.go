package bank

import (
	"reflect"
	"testing"
)

func displayItemData(
	t *testing.T,
	items []map[string]any,
	title string,
) []any {
	t.Helper()

	for _, item := range items {
		if item["title"] != title {
			continue
		}

		data, ok := item["data"].([]any)
		if !ok {
			t.Fatalf("%q data is not []any: %#v", title, item["data"])
		}

		return data
	}

	t.Fatalf("display item %q not found", title)
	return nil
}

func TestPaymentConsentDisplayData(t *testing.T) {
	receipt := map[string]any{
		"Data": map[string]any{
			"Initiation": map[string]any{
				"InstructionIdentification": "instruction-123",
				"EndToEndIdentification":    "e2e-456",
				"InstructedAmount": map[string]any{
					"Amount":   "125.00",
					"Currency": "GBP",
				},
				"DebtorAccount": map[string]any{
					"SchemeName":              "UK.OBIE.SortCodeAccountNumber",
					"Identification":          "1234567890",
					"Name":                    "Demo Debtor",
					"SecondaryIdentification": "secondary-debtor",
				},
				"CreditorAccount": map[string]any{
					"SchemeName":     "UK.OBIE.SortCodeAccountNumber",
					"Identification": "9988776655",
					"Name":           "Demo Creditor",
				},
			},
		},
	}

	got := buildPaymentConsentDisplayData(receipt)

	checks := map[string][]any{
		"Instruction Identification": {
			"instruction-123",
		},
		"End to End Identification": {
			"e2e-456",
		},
		"Instructed Amount": {
			"Amount :125.00",
			"Currency :GBP",
		},
		"Debtor Account": {
			"Scheme Name :UK.OBIE.SortCodeAccountNumber",
			"Identification :1234567890",
			"Name :Demo Debtor",
			"Secondary Identification :secondary-debtor",
		},
		"Creditor Account": {
			"Scheme Name :UK.OBIE.SortCodeAccountNumber",
			"Identification :9988776655",
			"Name :Demo Creditor",
		},
	}

	for title, want := range checks {
		if got := displayItemData(t, got, title); !reflect.DeepEqual(got, want) {
			t.Fatalf("%q: want %#v, got %#v", title, want, got)
		}
	}
}

func TestFundsConsentDisplayData(t *testing.T) {
	receipt := map[string]any{
		"Data": map[string]any{
			"ExpirationDateTime": "2027-09-01T00:00:00Z",
			"DebtorAccount": map[string]any{
				"SchemeName":     "UK.OBIE.SortCodeAccountNumber",
				"Identification": "1234567890",
				"Name":           "Demo Debtor",
			},
		},
	}

	got := buildFundsConsentDisplayData(receipt)

	if want := []any{"2027-09-01T00:00:00Z"}; !reflect.DeepEqual(
		displayItemData(t, got, "Expiration Date Time"),
		want,
	) {
		t.Fatalf("unexpected expiration display")
	}

	wantAccount := []any{
		"Scheme Name :UK.OBIE.SortCodeAccountNumber",
		"Identification :1234567890",
		"Name :Demo Debtor",
	}

	if got := displayItemData(t, got, "Debtor Account"); !reflect.DeepEqual(
		got,
		wantAccount,
	) {
		t.Fatalf("unexpected debtor account: %#v", got)
	}
}

func TestFundsConsentDisplayDataOpenEnded(t *testing.T) {
	receipt := map[string]any{
		"Data": map[string]any{},
	}

	got := buildFundsConsentDisplayData(receipt)

	want := []any{"Open Ended Authorisation Requested"}

	if got := displayItemData(t, got, "Expiration Date Time"); !reflect.DeepEqual(
		got,
		want,
	) {
		t.Fatalf("want %#v, got %#v", want, got)
	}
}

func TestConsentResourceType(t *testing.T) {
	resource := map[string]any{
		"type": " Payments ",
	}

	if got := consentResourceType(resource); got != "payments" {
		t.Fatalf("want payments, got %q", got)
	}
}
