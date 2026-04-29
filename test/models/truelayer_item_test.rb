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
end
