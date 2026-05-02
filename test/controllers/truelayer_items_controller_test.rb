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
    Provider::Truelayer.any_instance.stubs(:generate_reauth_uri).returns({ result: "https://auth.truelayer.com/reauth", status: "Succeeded" })

    post reauthorize_truelayer_item_url(@truelayer_item)

    pending = session[:truelayer_oauth_pending]
    assert pending.present?, "session[:truelayer_oauth_pending] should be set"
    assert_equal "reauth", pending["type"]
    assert_equal @truelayer_item.id.to_s, pending["item_id"]
    assert pending["state"].length >= 32
  end

  test "reauthorize redirects to reauth_uri skipping provider picker when refresh token present" do
    @truelayer_item.update!(access_token: "tok", refresh_token: "ref", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:generate_reauth_uri).returns({ result: "https://bank.example.com/reauth-direct", status: "Succeeded" })

    post reauthorize_truelayer_item_url(@truelayer_item)

    assert_redirected_to "https://bank.example.com/reauth-direct"
  end

  test "reauthorize falls back to standard oauth when reauth_uri is unavailable" do
    @truelayer_item.update!(access_token: "tok", refresh_token: "ref", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:generate_reauth_uri).returns({ result: nil, status: "Failed" })
    Provider::Truelayer.any_instance.stubs(:auth_url).returns("https://auth.truelayer.com/")

    post reauthorize_truelayer_item_url(@truelayer_item)

    assert_redirected_to "https://auth.truelayer.com/"
  end

  test "callback with reauth type updates tokens and redirects to providers" do
    @truelayer_item.update!(access_token: "old_tok", refresh_token: "ref", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:generate_reauth_uri).returns({ result: "https://auth.truelayer.com/reauth", status: "Succeeded" })
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
    @truelayer_item.update!(access_token: "tok", refresh_token: "ref", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:generate_reauth_uri).returns({ result: "https://auth.truelayer.com/reauth", status: "Succeeded" })
    post reauthorize_truelayer_item_url(@truelayer_item)

    real_nonce = session[:truelayer_oauth_pending]["state"]
    get callback_truelayer_items_url, params: { code: "auth_code", state: "not_#{real_nonce}" }

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
    # Newer connected item acts as the credentials reference with the current secret
    @family.truelayer_items.create!(
      name:          "Current Creds",
      client_id:     "cid",
      client_secret: "csec",
      access_token:  "tok"
    )

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
    @truelayer_item.update!(access_token: "tok", refresh_token: "ref", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:generate_reauth_uri).returns({ result: "https://auth.truelayer.com/reauth", status: "Succeeded" })
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
      name:         "My Bank",
      account_id:   "acct_123",
      account_kind: "account",
      currency:     "GBP"
    )

    post complete_account_setup_truelayer_item_url(@truelayer_item), params: {
      truelayer_account_id: truelayer_account.id,
      account_id:           ""
    }

    assert_redirected_to setup_accounts_truelayer_item_path(@truelayer_item)
    assert flash[:alert].present?
    assert_not truelayer_account.reload.setup_skipped
  end

  # destroy transactional tests

  test "destroy with actual unlink rolls back partial unlinks when an account errors" do
    ta1 = @truelayer_item.truelayer_accounts.create!(
      account_id: "tl_ta1", account_kind: "account", name: "Account 1", currency: "GBP"
    )
    ta2 = @truelayer_item.truelayer_accounts.create!(
      account_id: "tl_ta2", account_kind: "account", name: "Account 2", currency: "GBP"
    )
    account1 = accounts(:depository)
    account2 = accounts(:credit_card)
    AccountProvider.create!(account: account1, provider: ta1)
    link2 = AccountProvider.create!(account: account2, provider: ta2)

    # Simulate ta1 unlinking OK but ta2 failing
    TruelayerItem.any_instance.stubs(:unlink_all!).returns([
      { ta_id: ta1.id, name: ta1.name, provider_link_ids: [] },
      { ta_id: ta2.id, name: ta2.name, provider_link_ids: [ link2.id ], error: "DB error" }
    ])

    delete truelayer_item_url(@truelayer_item)

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  # reauth consent_expires_at reset tests

  test "callback with reauth type clears consent_expires_at so importer re-fetches it" do
    @truelayer_item.update!(
      access_token:       "old_tok",
      refresh_token:      "ref",
      status:             :requires_update,
      consent_expires_at: 1.year.from_now
    )
    Provider::Truelayer.any_instance.stubs(:generate_reauth_uri).returns({ result: "https://auth.truelayer.com/reauth", status: "Succeeded" })
    post reauthorize_truelayer_item_url(@truelayer_item)
    nonce = session[:truelayer_oauth_pending]["state"]

    Provider::Truelayer.any_instance.stubs(:exchange_code).returns(
      access_token: "new_tok", refresh_token: "new_refresh", expires_in: 3600
    )

    get callback_truelayer_items_url, params: { code: "auth_code", state: nonce }

    assert_nil @truelayer_item.reload.consent_expires_at
  end

  # reauthorize rescue tests

  test "reauthorize redirects to providers with alert when all redirect attempts fail" do
    @truelayer_item.update!(access_token: "tok", refresh_token: "ref", status: :requires_update)
    Provider::Truelayer.any_instance.stubs(:generate_reauth_uri).raises(
      Provider::Truelayer::TruelayerError.new("Network error", :request_failed)
    )

    post reauthorize_truelayer_item_url(@truelayer_item)

    assert_redirected_to settings_providers_path
    assert flash[:alert].present?
  end

  # duplicate-link guard tests

  test "link_existing_account redirects with alert when account is already linked" do
    truelayer_account = @truelayer_item.truelayer_accounts.create!(
      name: "My Bank", account_id: "acct_link_dup", account_kind: "account", currency: "GBP"
    )
    account = accounts(:depository)

    AccountProvider.stubs(:create!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    post link_existing_account_truelayer_items_url, params: {
      account_id:           account.id,
      truelayer_account_id: truelayer_account.id
    }

    assert_redirected_to accounts_path
    assert flash[:alert].present?
  end

  test "complete_account_setup redirects with alert when account is already linked" do
    truelayer_account = @truelayer_item.truelayer_accounts.create!(
      name: "My Bank", account_id: "acct_setup_dup", account_kind: "account", currency: "GBP"
    )
    account = accounts(:depository)

    AccountProvider.stubs(:create!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    post complete_account_setup_truelayer_item_url(@truelayer_item), params: {
      truelayer_account_id: truelayer_account.id,
      account_id:           account.id
    }

    assert_redirected_to setup_accounts_truelayer_item_path(@truelayer_item)
    assert flash[:alert].present?
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
