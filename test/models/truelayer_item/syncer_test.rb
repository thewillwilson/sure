require "test_helper"

class TruelayerItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @truelayer_item = TruelayerItem.create!(
      family:        @family,
      name:          "Test TrueLayer",
      client_id:     "cid",
      client_secret: "csec",
      access_token:  "tok"
    )
    @syncer = TruelayerItem::Syncer.new(@truelayer_item)
  end

  test "does not re-flag pending_account_setup for skipped accounts after sync" do
    TruelayerAccount.create!(
      truelayer_item: @truelayer_item,
      account_id:     "tl_skipped_001",
      account_kind:   "account",
      name:           "Skipped Account",
      currency:       "GBP",
      setup_skipped:  true
    )
    @truelayer_item.update!(pending_account_setup: false)

    mock_sync = mock("sync")
    mock_sync.stubs(:respond_to?).with(:status_text).returns(false)
    mock_sync.stubs(:respond_to?).with(:sync_stats).returns(false)
    mock_sync.stubs(:window_start_date).returns(nil)
    mock_sync.stubs(:window_end_date).returns(nil)
    mock_sync.stubs(:update!)

    @truelayer_item.stubs(:import_latest_truelayer_data).returns({ success: true })

    @syncer.perform_sync(mock_sync)

    refute @truelayer_item.reload.pending_account_setup?
  end

  test "consent_expiring_soon? is true when consent expires within 7 days" do
    @truelayer_item.update!(consent_expires_at: 5.days.from_now)
    @truelayer_item.stubs(:import_latest_truelayer_data).returns({ success: true })

    @syncer.perform_sync(build_mock_sync)

    assert @truelayer_item.reload.consent_expiring_soon?
  end

  test "transitions to requires_update when token cannot be refreshed after consent expiry" do
    @truelayer_item.update!(
      token_expires_at:   1.minute.ago,
      consent_expires_at: 2.days.ago
    )
    # Stub refresh as a no-op so token_expires_at remains in the past and token_valid? stays false
    @truelayer_item.stubs(:refresh_tokens!)

    assert_raises(StandardError) { @syncer.perform_sync(build_mock_sync) }

    assert @truelayer_item.reload.requires_update?
  end

  test "raises when import_latest_truelayer_data raises an error" do
    @truelayer_item.stubs(:import_latest_truelayer_data).raises(StandardError.new("provider API down"))

    assert_raises(StandardError) { @syncer.perform_sync(build_mock_sync) }
  end

  test "pending_account_setup stays false when all accounts are linked" do
    @truelayer_item.update!(pending_account_setup: true)

    tl_account = build_truelayer_account("tl_linked_001")
    account = @family.accounts.create!(
      accountable: OtherAsset.create!,
      name: "Linked Account",
      balance: 0,
      currency: "GBP"
    )
    AccountProvider.create!(account: account, provider: tl_account)

    @truelayer_item.stubs(:import_latest_truelayer_data).returns({ success: true })
    @truelayer_item.stubs(:schedule_account_syncs)

    @syncer.perform_sync(build_mock_sync)

    refute @truelayer_item.reload.pending_account_setup?
  end

  test "pending_account_setup becomes true when unlinked accounts exist after sync" do
    @truelayer_item.update!(pending_account_setup: false)
    build_truelayer_account("tl_unlinked_001")

    @truelayer_item.stubs(:import_latest_truelayer_data).returns({ success: true })

    @syncer.perform_sync(build_mock_sync)

    assert @truelayer_item.reload.pending_account_setup?
  end

  test "forwards sync window dates to schedule_account_syncs" do
    start_date = 30.days.ago.to_date
    end_date   = Date.current

    tl_account = build_truelayer_account("tl_windowed_001")
    account = @family.accounts.create!(
      accountable: OtherAsset.create!,
      name: "Windowed Account",
      balance: 0,
      currency: "GBP"
    )
    AccountProvider.create!(account: account, provider: tl_account)

    @truelayer_item.stubs(:import_latest_truelayer_data).returns({ success: true })
    @truelayer_item.expects(:schedule_account_syncs).with(
      parent_sync:       anything,
      window_start_date: start_date,
      window_end_date:   end_date
    )

    @syncer.perform_sync(build_mock_sync(window_start: start_date, window_end: end_date))
  end

  test "syncs successfully when item status is already requires_update but token is valid" do
    @truelayer_item.update!(status: :requires_update)
    @truelayer_item.stubs(:import_latest_truelayer_data).returns({ success: true })

    assert_nothing_raised { @syncer.perform_sync(build_mock_sync) }

    # The syncer does not reset status to :good on a successful sync; that's done elsewhere
    assert @truelayer_item.reload.requires_update?
  end

  private

    def build_mock_sync(window_start: nil, window_end: nil)
      s = mock("sync")
      s.stubs(:respond_to?).with(:status_text).returns(false)
      s.stubs(:respond_to?).with(:sync_stats).returns(false)
      s.stubs(:window_start_date).returns(window_start)
      s.stubs(:window_end_date).returns(window_end)
      s.stubs(:update!)
      s
    end

    def build_truelayer_account(account_id, setup_skipped: false)
      TruelayerAccount.create!(
        truelayer_item: @truelayer_item,
        account_id:     account_id,
        account_kind:   "account",
        name:           "Test Account #{account_id}",
        currency:       "GBP",
        setup_skipped:  setup_skipped
      )
    end
end
