require "test_helper"

class TruelayerItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @truelayer_item = TruelayerItem.create!(
      family:        @family,
      name:          "Test TrueLayer",
      client_id:     "cid",
      client_secret: "csec",
      access_token:  "tok"
    )
    @truelayer_account = TruelayerAccount.create!(
      truelayer_item: @truelayer_item,
      account_id:     "tl_acc_001",
      account_kind:   "account",
      name:           "Current Account",
      currency:       "GBP"
    )
    AccountProvider.create!(account: @account, provider: @truelayer_account)
    @truelayer_item.update!(consent_expires_at: 90.days.from_now)
    @importer = TruelayerItem::Importer.new(@truelayer_item)
  end

  test "marks item requires_update when balance fetch returns unauthorized" do
    mock_provider = mock("provider")
    mock_provider.stubs(:get_accounts).returns([])
    mock_provider.stubs(:get_cards).raises(Provider::Truelayer::TruelayerError.new("Not Implemented", :not_implemented))
    mock_provider.stubs(:get_transactions).returns([])
    mock_provider.stubs(:get_pending_transactions).returns([])
    mock_provider.stubs(:get_balance).raises(Provider::Truelayer::TruelayerError.new("Unauthorized", :unauthorized))

    @truelayer_item.stubs(:truelayer_provider).returns(mock_provider)

    @importer.import

    assert_equal "requires_update", @truelayer_item.reload.status
  end

  test "sets card account balance to debt owed and stores available credit separately" do
    card_account = accounts(:credit_card)
    card_ta = TruelayerAccount.create!(
      truelayer_item: @truelayer_item,
      account_id:     "tl_card_001",
      account_kind:   "card",
      name:           "Visa",
      currency:       "GBP"
    )
    AccountProvider.create!(account: card_account, provider: card_ta)

    mock_provider = mock("provider")
    mock_provider.stubs(:get_accounts).returns([])
    mock_provider.stubs(:get_cards).returns([])
    mock_provider.stubs(:get_transactions).returns([])
    mock_provider.stubs(:get_pending_transactions).returns([])
    mock_provider.stubs(:get_balance).with(account_id: "tl_acc_001", kind: "account", psu_ip: anything).returns(
      { current: 500.0, currency: "GBP" }
    )
    mock_provider.stubs(:get_balance).with(account_id: "tl_card_001", kind: "card", psu_ip: anything).returns(
      { available: 3279.0, current: -20.0, credit_limit: 3300.0, currency: "GBP" }
    )

    @truelayer_item.stubs(:truelayer_provider).returns(mock_provider)
    @importer.import

    assert_in_delta 20.0, card_account.reload.balance.to_f, 0.01
    assert_in_delta 3279.0, card_account.credit_card.reload.available_credit.to_f, 0.01
  end

  test "sets card balance to debt when available credit is absent" do
    card_account = accounts(:credit_card)
    card_ta = TruelayerAccount.create!(
      truelayer_item: @truelayer_item,
      account_id:     "tl_card_002",
      account_kind:   "card",
      name:           "Mastercard",
      currency:       "GBP"
    )
    AccountProvider.create!(account: card_account, provider: card_ta)

    mock_provider = mock("provider")
    mock_provider.stubs(:get_accounts).returns([])
    mock_provider.stubs(:get_cards).returns([])
    mock_provider.stubs(:get_transactions).returns([])
    mock_provider.stubs(:get_pending_transactions).returns([])
    mock_provider.stubs(:get_balance).with(account_id: "tl_acc_001", kind: "account", psu_ip: anything).returns(
      { current: 500.0, currency: "GBP" }
    )
    mock_provider.stubs(:get_balance).with(account_id: "tl_card_002", kind: "card", psu_ip: anything).returns(
      { current: -20.0, currency: "GBP" }
    )

    @truelayer_item.stubs(:truelayer_provider).returns(mock_provider)
    @importer.import

    assert_in_delta 20.0, card_account.reload.balance.to_f, 0.01
  end

  test "imports cards when provider does not support accounts endpoint" do
    card_data = { "account_id" => "tl_card_amex_001", "display_name" => "Amex Gold Card", "currency" => "GBP" }

    mock_provider = mock("provider")
    mock_provider.stubs(:get_accounts).raises(Provider::Truelayer::TruelayerError.new("Endpoint not supported by this provider", :not_implemented))
    mock_provider.stubs(:get_cards).returns([ card_data ])
    mock_provider.stubs(:get_transactions).returns([])
    mock_provider.stubs(:get_pending_transactions).returns([])
    mock_provider.stubs(:get_balance).returns(nil)

    @truelayer_item.stubs(:truelayer_provider).returns(mock_provider)

    assert_difference "@truelayer_item.truelayer_accounts.count", 1 do
      @importer.import
    end

    card = @truelayer_item.truelayer_accounts.find_by(account_id: "tl_card_amex_001")
    assert_equal "card", card.account_kind
  end

  test "does not set pending_account_setup when only skipped accounts are unlinked" do
    skipped_ta = TruelayerAccount.create!(
      truelayer_item: @truelayer_item,
      account_id:     "tl_skipped_001",
      account_kind:   "account",
      name:           "Skipped Account",
      currency:       "GBP",
      setup_skipped:  true
    )

    mock_provider = mock("provider")
    mock_provider.stubs(:get_accounts).returns([])
    mock_provider.stubs(:get_cards).raises(Provider::Truelayer::TruelayerError.new("Not Implemented", :not_implemented))
    mock_provider.stubs(:get_transactions).returns([])
    mock_provider.stubs(:get_pending_transactions).returns([])
    mock_provider.stubs(:get_balance).returns(nil)

    @truelayer_item.stubs(:truelayer_provider).returns(mock_provider)
    @truelayer_item.update!(pending_account_setup: false)

    @importer.import

    assert_equal false, @truelayer_item.reload.pending_account_setup
  end

  test "marks item requires_update when transaction fetch returns unauthorized" do
    mock_provider = mock("provider")
    mock_provider.stubs(:get_accounts).returns([])
    mock_provider.stubs(:get_cards).raises(Provider::Truelayer::TruelayerError.new("Not Implemented", :not_implemented))
    mock_provider.stubs(:get_transactions).raises(Provider::Truelayer::TruelayerError.new("Unauthorized", :unauthorized))
    mock_provider.stubs(:get_balance).returns(nil)

    @truelayer_item.stubs(:truelayer_provider).returns(mock_provider)

    @importer.import

    assert_equal "requires_update", @truelayer_item.reload.status
  end

  test "skips transaction import and balance update when pending_account_setup is true" do
    # Create an unlinked account so update_pending_account_setup! keeps the flag true
    TruelayerAccount.create!(
      truelayer_item: @truelayer_item,
      account_id:     "tl_unlinked_001",
      account_kind:   "account",
      name:           "Unlinked Account",
      currency:       "GBP"
    )
    @truelayer_item.update!(pending_account_setup: true)

    mock_provider = mock("provider")
    mock_provider.stubs(:get_accounts).returns([])
    mock_provider.stubs(:get_cards).raises(Provider::Truelayer::TruelayerError.new("Not Implemented", :not_implemented))
    mock_provider.expects(:get_transactions).never
    mock_provider.expects(:get_pending_transactions).never
    mock_provider.expects(:get_balance).never

    @truelayer_item.stubs(:truelayer_provider).returns(mock_provider)
    @importer.import
  end
end
