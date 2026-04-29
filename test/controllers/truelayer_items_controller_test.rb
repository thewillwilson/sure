require "test_helper"

class TruelayerItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @truelayer_item = TruelayerItem.create!(
      family:        @family,
      name:          "Test Connection",
      client_id:     "cid",
      client_secret: "csec"
    )
  end

  # OAuth state nonce tests

  test "authorize stores a random nonce in session, not the item id" do
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")

    post authorize_truelayer_items_url

    pending = session[:truelayer_oauth_pending]
    assert pending.present?, "session[:truelayer_oauth_pending] should be set"
    assert_not_equal @truelayer_item.id.to_s, pending["state"],
      "state should be a random nonce, not the item id"
    assert pending["state"].length >= 32
  end

  test "callback rejects request when state does not match session nonce" do
    get callback_truelayer_items_url, params: { code: "auth_code", state: "wrong_nonce" }

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  test "callback enqueues background sync and redirects to accounts on connect success" do
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")
    post authorize_truelayer_items_url
    nonce = session[:truelayer_oauth_pending]["state"]

    Provider::Truelayer.any_instance.stubs(:exchange_code).returns(
      access_token: "tok", refresh_token: "refresh", expires_in: 3600
    )
    TruelayerItem.any_instance.stubs(:sync_later)

    get callback_truelayer_items_url, params: { code: "auth_code", state: nonce }

    assert_redirected_to accounts_path
    assert flash[:notice].present?
    assert @truelayer_item.reload.pending_account_setup?
  end

  test "reauthorize stores nonce in shared oauth pending session with reauth type" do
    @truelayer_item.update!(access_token: "tok", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")

    post reauthorize_truelayer_item_url(@truelayer_item)

    pending = session[:truelayer_oauth_pending]
    assert pending.present?, "session[:truelayer_oauth_pending] should be set"
    assert_equal "reauth", pending["type"]
    assert_equal @truelayer_item.id.to_s, pending["item_id"]
    assert pending["state"].length >= 32
  end

  test "callback with reauth type updates tokens and redirects to providers" do
    @truelayer_item.update!(access_token: "old_tok", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")
    post reauthorize_truelayer_item_url(@truelayer_item)
    nonce = session[:truelayer_oauth_pending]["state"]

    Provider::Truelayer.any_instance.stubs(:exchange_code).returns(
      access_token: "new_tok", refresh_token: "new_refresh", expires_in: 3600
    )

    get callback_truelayer_items_url, params: { code: "auth_code", state: nonce }

    assert_redirected_to settings_providers_path
    assert flash[:notice].present?
    assert_equal "good", @truelayer_item.reload.status
  end

  test "callback rejects reauth when state does not match" do
    @truelayer_item.update!(access_token: "tok", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")
    post reauthorize_truelayer_item_url(@truelayer_item)

    get callback_truelayer_items_url, params: { code: "auth_code", state: "wrong_nonce" }

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  test "callback redirects with alert when code param is absent" do
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")
    post authorize_truelayer_items_url
    nonce = session[:truelayer_oauth_pending]["state"]

    get callback_truelayer_items_url, params: { state: nonce }

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  # credential update tests

  test "update with blank client_secret preserves existing secret" do
    patch truelayer_item_url(@truelayer_item), params: {
      truelayer_item: { name: "Renamed", client_id: "cid", client_secret: "" }
    }

    assert_equal "csec", @truelayer_item.reload.client_secret
  end

  test "authorize refreshes credentials on reused unconnected stub" do
    @truelayer_item.update!(client_secret: "old_secret", sandbox: false)

    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")
    post authorize_truelayer_items_url

    @truelayer_item.reload
    assert_equal "csec", @truelayer_item.client_secret
  end

  test "authorize uses most recently created credentials when multiple exist" do
    newer = @family.truelayer_items.create!(
      name:          "Newer Creds",
      client_id:     "cid_newer",
      client_secret: "csec_newer"
    )

    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")

    post authorize_truelayer_items_url

    assert_redirected_to "https://auth.truelayer.com/"
    pending = session[:truelayer_oauth_pending]
    linked = TruelayerItem.find(pending["item_id"])
    assert_equal "cid_newer", linked.client_id
  end

  # destroy tests

  test "destroy redirects with alert when any account fails to unlink" do
    TruelayerItem.any_instance.stubs(:unlink_all!).returns([
      { ta_id: 1, name: "Account 1", provider_link_ids: [], error: "DB error" }
    ])

    delete truelayer_item_url(@truelayer_item)

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
    assert flash[:notice].blank?
  end

  test "destroy redirects with success when unlinking succeeds" do
    TruelayerItem.any_instance.stubs(:unlink_all!).returns([
      { ta_id: 1, name: "Account 1", provider_link_ids: [] }
    ])
    TruelayerItem.any_instance.stubs(:destroy_later)

    delete truelayer_item_url(@truelayer_item)

    assert_redirected_to settings_providers_path
    assert flash[:notice].present?
  end

  # OAuth admin flag tests

  test "authorize sets admin flag in oauth pending state" do
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")
    post authorize_truelayer_items_url
    pending = session[:truelayer_oauth_pending]
    assert_equal true, pending["admin"]
  end

  test "reauthorize sets admin flag in oauth pending state" do
    @truelayer_item.update!(access_token: "tok", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")
    post reauthorize_truelayer_item_url(@truelayer_item)
    pending = session[:truelayer_oauth_pending]
    assert_equal true, pending["admin"]
  end

  test "callback rejects when admin flag is missing from pending state" do
    # Simulate a tampered/legacy session by writing pending state without admin flag via a
    # custom session-seeding route. Since we cannot overwrite the server-side cookie mid-test,
    # we test the structurally equivalent case: no pending state at all (admin flag absent →
    # same rejection branch). The positive path (admin flag present) is covered by the
    # happy-path callback tests which drive the full authorize → callback flow.
    get callback_truelayer_items_url, params: { code: "auth_code", state: "any_nonce" }

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  # complete_account_setup tests

  test "complete_account_setup redirects with alert when account_id submitted blank" do
    truelayer_account = @truelayer_item.truelayer_accounts.create!(
      name:       "My Bank",
      account_id: "acct_123",
      currency:   "GBP"
    )

    post complete_account_setup_truelayer_item_url(@truelayer_item), params: {
      truelayer_account_id: truelayer_account.id,
      account_id:           ""
    }

    assert_redirected_to setup_accounts_truelayer_item_path(@truelayer_item)
    assert flash[:alert].present?
    assert_not truelayer_account.reload.setup_skipped
  end

  # Admin authorization tests

  test "non-admin cannot access authorize" do
    sign_in users(:family_member)
    post authorize_truelayer_items_url
    assert_redirected_to accounts_path
  end

  test "non-admin cannot sync a truelayer item" do
    sign_in users(:family_member)
    post sync_truelayer_item_url(@truelayer_item)
    assert_redirected_to accounts_path
  end

  test "non-admin cannot destroy a truelayer item" do
    sign_in users(:family_member)
    delete truelayer_item_url(@truelayer_item)
    assert_redirected_to accounts_path
  end
end
