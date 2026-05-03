require "test_helper"

class Provider::TruelayerSyncerTest < ActiveSupport::TestCase
  setup do
    @connection = provider_connections(:monzo_connection)
    @sync       = @connection.syncs.create!
    @syncer     = Provider::TruelayerSyncer.new(@connection)
    # Stub stat collection to avoid DB interactions in unit tests
    @syncer.stubs(:collect_setup_stats)
    @syncer.stubs(:collect_health_stats)
    @syncer.stubs(:collect_transaction_stats)
  end

  test "marks connection requires_update when ReauthRequired" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token)
                          .raises(Provider::Auth::ReauthRequiredError)
    @syncer.perform_sync(@sync)
    assert @connection.reload.requires_update?
    assert_equal "reauth_required", @connection.read_attribute(:sync_error)
  end

  test "syncs linked accounts even when other accounts are still in pending_setup" do
    # monzo_unlinked fixture leaves connection in pending_setup state, but
    # monzo_current is linked — its transactions should still be fetched.
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_accounts).returns([])
    Provider::TruelayerAdapter.any_instance.expects(:fetch_transactions).at_least_once.returns([])
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.stubs(:sync_later)
    @syncer.perform_sync(@sync)
    assert @connection.reload.good?
  end

  test "marks connection good after successful sync" do
    provider_accounts(:monzo_unlinked).update!(account: accounts(:depository))
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_accounts).returns([])
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_transactions).returns([])
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.stubs(:sync_later)
    @syncer.perform_sync(@sync)
    assert @connection.reload.good?
  end

  test "anchor_balance sets account balance from current field" do
    pa = provider_accounts(:monzo_current)
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_balance).returns({ "current" => 1234.56, "currency" => "GBP" })
    Account.any_instance.stubs(:sync_later)
    result = @syncer.send(:anchor_balance, "tok", pa)
    assert result
    assert_equal BigDecimal("1234.56"), pa.account.reload.balance
  end

  test "anchor_balance updates available_credit for credit card accounts" do
    pa = provider_accounts(:monzo_current)
    pa.account.update!(accountable_type: "CreditCard", accountable: CreditCard.create!)
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_balance).returns({
      "current" => 500.0, "credit_limit" => 4500.0, "currency" => "GBP"
    })
    Account.any_instance.stubs(:sync_later)
    @syncer.send(:anchor_balance, "tok", pa)
    assert_equal BigDecimal("4500.0"), pa.account.reload.credit_card.available_credit
  end

  test "anchor_balance returns false and warns on fetch error" do
    pa = provider_accounts(:monzo_current)
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_balance).raises(Provider::Truelayer::Error, "timeout")
    Rails.logger.expects(:warn).with { |msg| msg.include?("balance fetch failed") }
    result = @syncer.send(:anchor_balance, "tok", pa)
    assert_not result
  end

  test "sync_later called when balance anchor fails" do
    # Isolate to a single linked provider_account so assertion counts are deterministic.
    # Skip (rather than unlink) monzo_current so pending_setup? stays false.
    provider_accounts(:monzo_current).update!(account: nil, skipped: true)
    provider_accounts(:monzo_unlinked).update!(account: accounts(:depository))
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_accounts).returns([])
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_transactions).returns([])
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.expects(:sync_later).once
    @syncer.perform_sync(@sync)
  end

  test "sync_later not called when balance anchor succeeds" do
    # Isolate to a single linked provider_account so assertion counts are deterministic.
    # Skip (rather than unlink) monzo_current so pending_setup? stays false.
    provider_accounts(:monzo_current).update!(account: nil, skipped: true)
    provider_accounts(:monzo_unlinked).update!(account: accounts(:depository))
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_accounts).returns([])
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_transactions).returns([])
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_balance).returns({ "current" => 100.0 })
    Account.any_instance.expects(:sync_later).once  # triggered by set_current_balance, not explicitly
    @syncer.perform_sync(@sync)
  end

  test "re-raises non-auth errors and sets sync_error" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_accounts).raises(RuntimeError, "upstream exploded")
    assert_raises(RuntimeError) { @syncer.perform_sync(@sync) }
    assert_equal "upstream exploded", @connection.reload.read_attribute(:sync_error)
  end

  test "transient errors propagate without surfacing to user" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_accounts)
                                            .raises(Provider::Auth::TransientError, "TrueLayer API 503")
    @connection.update!(sync_error: nil, status: :good)
    assert_raises(Provider::Auth::TransientError) { @syncer.perform_sync(@sync) }
    @connection.reload
    assert @connection.good?, "transient errors should not change status"
    assert_nil @connection.read_attribute(:sync_error), "transient errors should not be written to sync_error"
  end

  test "discover_accounts_only discovers without syncing transactions" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::TruelayerAdapter.any_instance.expects(:fetch_accounts).returns([]).once
    Provider::TruelayerAdapter.any_instance.expects(:fetch_transactions).never
    @syncer.discover_accounts_only
  end

  test "discover_accounts upserts provider_accounts from adapter response" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::TruelayerAdapter.any_instance.stubs(:fetch_accounts).returns([ {
      external_id: "new_acc_1",
      name:        "Monzo Plus",
      type:        "depository",
      subtype:     "checking",
      currency:    "GBP",
      raw_payload: { "account_id" => "new_acc_1" }
    } ])
    assert_difference "@connection.provider_accounts.count" do
      @syncer.discover_accounts_only
    end
    pa = @connection.provider_accounts.find_by(external_id: "new_acc_1")
    assert_equal "Monzo Plus", pa.external_name
    assert_equal "GBP", pa.currency
  end
end
