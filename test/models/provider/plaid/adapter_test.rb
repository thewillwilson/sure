require "test_helper"

class Provider::Plaid::AdapterTest < ActiveSupport::TestCase
  test "registered with ConnectionRegistry under plaid_us and plaid_eu" do
    assert_equal Provider::Plaid::Adapter, Provider::ConnectionRegistry.adapter_for("plaid_us")
    assert_equal Provider::Plaid::Adapter, Provider::ConnectionRegistry.adapter_for("plaid_eu")
  end

  test "auth_class is EmbeddedLink" do
    assert_equal Provider::Auth::EmbeddedLink, Provider::Plaid::Adapter.auth_class
  end

  test "syncer_class is Provider::Plaid::Syncer" do
    assert_equal Provider::Plaid::Syncer, Provider::Plaid::Adapter.syncer_class
  end

  test "supported_account_types covers depository, credit, loan, investment" do
    assert_equal %w[Depository CreditCard Loan Investment],
                 Provider::Plaid::Adapter.supported_account_types
  end

  test "build_sure_account maps depository to Depository with subtype" do
    family = families(:empty)
    pa = build_provider_account(external_type: "depository", external_subtype: "checking",
                                external_name: "Chase Checking", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: family)
    assert_instance_of Depository, account.accountable
    assert_equal "checking", account.accountable.subtype
    assert_equal "Chase Checking", account.name
    assert_equal "USD", account.currency
  end

  test "build_sure_account maps credit to CreditCard" do
    pa = build_provider_account(external_type: "credit", external_subtype: "credit card",
                                external_name: "Chase CC", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    assert_instance_of CreditCard, account.accountable
    assert_equal "credit_card", account.accountable.subtype
  end

  test "build_sure_account maps investment with brokerage subtype" do
    pa = build_provider_account(external_type: "investment", external_subtype: "brokerage",
                                external_name: "Fidelity", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    assert_instance_of Investment, account.accountable
    assert_equal "brokerage", account.accountable.subtype
  end

  test "build_sure_account maps loan with mortgage subtype" do
    pa = build_provider_account(external_type: "loan", external_subtype: "mortgage",
                                external_name: "Mortgage", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    assert_instance_of Loan, account.accountable
    assert_equal "mortgage", account.accountable.subtype
  end

  test "build_sure_account raises for unknown external_type" do
    pa = build_provider_account(external_type: "crypto", external_subtype: nil,
                                external_name: "?", currency: "USD")
    assert_raises(Provider::Account::UnsupportedAccountableType) do
      Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    end
  end

  test "build_sure_account falls back to 'other' subtype for unknown subtype" do
    pa = build_provider_account(external_type: "depository", external_subtype: "unknown_subtype",
                                external_name: "Mystery", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    assert_equal "other", account.accountable.subtype
  end

  private

    def build_provider_account(external_type:, external_subtype:, external_name:, currency:)
      conn = Provider::Connection.create!(
        family: families(:empty), provider_key: "plaid_us",
        auth_type: "embedded_link", credentials: {}, status: :good
      )
      Provider::Account.create!(
        provider_connection: conn,
        external_id:         "acc_#{SecureRandom.hex(4)}",
        external_name:       external_name,
        external_type:       external_type,
        external_subtype:    external_subtype,
        currency:            currency,
        raw_payload:         {}
      )
    end
end
