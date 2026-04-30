require "test_helper"

class TruelayerItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "syncable scope excludes items without access_token even if token_expires_at is set" do
    item = TruelayerItem.create!(
      family:           @family,
      name:             "No Token",
      client_id:        "cid",
      client_secret:    "csec",
      token_expires_at: 1.hour.from_now
    )
    refute_includes TruelayerItem.syncable.map(&:id), item.id
  end

  test "syncable scope includes items with access_token and no expiry" do
    item = TruelayerItem.create!(
      family:        @family,
      name:          "Token No Expiry",
      client_id:     "cid",
      client_secret: "csec",
      access_token:  "tok123"
    )
    assert_includes TruelayerItem.syncable.map(&:id), item.id
  end

  test "refresh_tokens! updates access_token, refresh_token, expiry, and status" do
    item = TruelayerItem.create!(
      family:           @family,
      name:             "Refresh Test",
      client_id:        "cid",
      client_secret:    "csec",
      access_token:     "old_access",
      refresh_token:    "old_refresh",
      token_expires_at: 30.seconds.from_now
    )

    Provider::Truelayer.any_instance.expects(:refresh_access_token)
      .with(refresh_token: "old_refresh")
      .returns({ access_token: "new_access", refresh_token: "new_refresh", expires_in: 3600 })

    item.refresh_tokens!
    item.reload

    assert_equal "new_access", item.access_token
    assert_equal "new_refresh", item.refresh_token
    assert_in_delta 3600, item.token_expires_at - Time.current, 5
    assert_equal "good", item.status
  end

  test "refresh_tokens! uses exclusive lock to prevent concurrent token rotation" do
    item = TruelayerItem.create!(
      family:        @family,
      name:          "Lock Test",
      client_id:     "cid",
      client_secret: "csec",
      access_token:  "old_access",
      refresh_token: "old_refresh"
    )

    Provider::Truelayer.any_instance.stubs(:refresh_access_token)
      .returns({ access_token: "new_access", refresh_token: "new_refresh", expires_in: 3600 })

    item.expects(:with_lock).yields
    item.refresh_tokens!
  end

  test "syncable scope excludes items with requires_update status" do
    item = TruelayerItem.create!(
      family:        @family,
      name:          "Needs Reauth",
      client_id:     "cid",
      client_secret: "csec",
      access_token:  "tok",
      status:        :requires_update
    )
    refute_includes TruelayerItem.syncable.map(&:id), item.id
  end

  test "refresh_tokens! transitions to requires_update on invalid_grant response" do
    item = TruelayerItem.create!(
      family:        @family,
      name:          "Invalid Grant Test",
      client_id:     "cid",
      client_secret: "csec",
      access_token:  "expired_access",
      refresh_token: "expired_refresh"
    )

    Provider::Truelayer.any_instance.stubs(:refresh_access_token).raises(
      Provider::Truelayer::TruelayerError.new("invalid_grant: refresh token expired", :bad_request)
    )

    assert_raises(StandardError) { item.refresh_tokens! }
    assert_equal "requires_update", item.reload.status
  end

  test "import_latest_truelayer_data triggers token refresh for legacy rows with access_token but no expiry" do
    item = TruelayerItem.create!(
      family:        @family,
      name:          "Legacy Token",
      client_id:     "cid",
      client_secret: "csec",
      access_token:  "legacy_access",
      refresh_token: "legacy_refresh"
    )

    Provider::Truelayer.any_instance.stubs(:refresh_access_token).returns(
      { access_token: "new_access", refresh_token: "new_refresh", expires_in: 3600 }
    )
    TruelayerItem::Importer.any_instance.stubs(:import).returns({ success: true })

    item.import_latest_truelayer_data

    assert_equal "new_access", item.reload.access_token
    assert_not_nil item.reload.token_expires_at
  end

  test "unlink_all! destroys account provider links and reports results without error" do
    item = TruelayerItem.create!(
      family:        @family,
      name:          "Unlink Test",
      client_id:     "cid",
      client_secret: "csec"
    )
    ta = item.truelayer_accounts.create!(
      account_id:   "tl_unlink_001",
      account_kind: "account",
      name:         "Test Account",
      currency:     "GBP"
    )
    account = accounts(:depository)
    link = AccountProvider.create!(account: account, provider: ta)

    results = nil
    assert_difference "AccountProvider.count", -1 do
      results = item.unlink_all!(dry_run: false)
    end

    assert_equal 1, results.length
    assert_equal ta.id, results.first[:ta_id]
    assert_includes results.first[:provider_link_ids], link.id
    assert_nil results.first[:error]
  end

  test "allows multiple active items with the same client_id for the same family" do
    TruelayerItem.create!(
      family:        @family,
      name:          "First",
      client_id:     "shared_cid",
      client_secret: "csec"
    )

    second = TruelayerItem.new(
      family:        @family,
      name:          "Second",
      client_id:     "shared_cid",
      client_secret: "csec"
    )

    assert second.valid?
  end

  test "import_latest_truelayer_data proceeds after successful token refresh even when new token is very short-lived" do
    item = TruelayerItem.create!(
      family:           @family,
      name:             "Short Token",
      client_id:        "cid",
      client_secret:    "csec",
      access_token:     "old_access",
      refresh_token:    "old_refresh",
      token_expires_at: 10.seconds.from_now
    )

    Provider::Truelayer.any_instance.stubs(:refresh_access_token)
      .returns({ access_token: "new_access", refresh_token: "new_refresh", expires_in: 1 })

    TruelayerItem::Importer.any_instance.expects(:import).once.returns({ success: true })

    item.import_latest_truelayer_data
  end
end
