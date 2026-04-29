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
end
