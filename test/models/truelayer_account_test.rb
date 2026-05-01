require "test_helper"

class TruelayerAccountTest < ActiveSupport::TestCase
  test "display_type returns app subtype label for checking account" do
    ta = TruelayerAccount.new(account_type: "TRANSACTION", account_kind: "bank", currency: "GBP")
    assert_equal Depository.short_subtype_label_for("checking"), ta.display_type
  end

  test "display_type returns app subtype label for savings account" do
    ta = TruelayerAccount.new(account_type: "SAVINGS", account_kind: "bank", currency: "GBP")
    assert_equal Depository.short_subtype_label_for("savings"), ta.display_type
  end

  test "display_type returns app subtype label for credit card" do
    ta = TruelayerAccount.new(account_type: nil, account_kind: "card", currency: "GBP")
    assert_equal CreditCard.short_subtype_label_for("credit_card"), ta.display_type
  end

  test "display_type humanizes unknown account type as fallback" do
    ta = TruelayerAccount.new(account_type: "PENSION_FUND", account_kind: "bank", currency: "GBP")
    assert_equal "Pension fund", ta.display_type
  end

  test "provider_display_name parses JSON string raw_payload" do
    ta = TruelayerAccount.new(raw_payload: '{"provider":{"display_name":"Monzo","logo_uri":"https://example.com/logo.png"}}')
    assert_equal "Monzo", ta.provider_display_name
  end

  test "provider_display_name returns nil when raw_payload is nil" do
    ta = TruelayerAccount.new(raw_payload: nil)
    assert_nil ta.provider_display_name
  end

  test "provider_logo_uri parses JSON string raw_payload" do
    ta = TruelayerAccount.new(raw_payload: '{"provider":{"display_name":"Monzo","logo_uri":"https://example.com/logo.png"}}')
    assert_equal "https://example.com/logo.png", ta.provider_logo_uri
  end

  test "masked_account_number parses JSON string raw_payload" do
    ta = TruelayerAccount.new(raw_payload: '{"account_number":{"number":"12345678","sort_code":"040004"}}')
    assert_equal "••••5678", ta.masked_account_number
  end
end
