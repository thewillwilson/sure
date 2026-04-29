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
end
