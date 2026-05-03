require "test_helper"

class OauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  FAKE_AUTH_URL = "https://auth.truelayer.com/?response_type=code&client_id=test"

  setup do
    sign_in users(:family_admin)
    provider_family_configs(:truelayer_family_one)
    Provider::Auth::OAuth2.any_instance.stubs(:authorize_url).returns(FAKE_AUTH_URL)
  end

  test "new redirects to TrueLayer auth URL" do
    post new_oauth_callbacks_path(provider: "truelayer")
    assert_response :redirect
    assert_match "auth.truelayer.com", response.location
  end

  test "new creates a pending provider_connection" do
    assert_difference "Provider::Connection.count" do
      post new_oauth_callbacks_path(provider: "truelayer")
    end
    conn = Provider::Connection.order(created_at: :desc).first
    assert conn.pending?
    assert_equal "truelayer", conn.provider_key
  end

  test "new stores psu_ip in connection metadata when client IP is public" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "203.0.113.42" }
    conn = Provider::Connection.order(created_at: :desc).first
    assert_equal "203.0.113.42", conn.metadata["psu_ip"]
  end

  test "new omits psu_ip when client IP is private or loopback" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "127.0.0.1" }
    conn = Provider::Connection.order(created_at: :desc).first
    assert_nil conn.metadata["psu_ip"]
  end

  test "new omits psu_ip for CGNAT (100.64.0.0/10) addresses" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "100.64.1.42" }
    conn = Provider::Connection.order(created_at: :desc).first
    assert_nil conn.metadata["psu_ip"]
  end

  test "new omits psu_ip for IPv4 link-local (cloud metadata) addresses" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "169.254.169.254" }
    conn = Provider::Connection.order(created_at: :desc).first
    assert_nil conn.metadata["psu_ip"]
  end

  test "new omits psu_ip for IPv6 link-local addresses" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "fe80::1" }
    conn = Provider::Connection.order(created_at: :desc).first
    assert_nil conn.metadata["psu_ip"]
  end

  test "create exchanges code and redirects to setup" do
    post new_oauth_callbacks_path(provider: "truelayer")
    conn = Provider::Connection.order(created_at: :desc).first

    Provider::Auth::OAuth2.any_instance.expects(:exchange_code).once
    Provider::Connection.any_instance.expects(:discover_accounts!).once

    get create_oauth_callbacks_path(provider: "truelayer",
                                    code: "auth_code",
                                    state: conn.id)
    assert_redirected_to setup_provider_connection_path(conn)
  end

  test "create rejects state mismatch without exchanging code" do
    post new_oauth_callbacks_path(provider: "truelayer")

    Provider::Auth::OAuth2.any_instance.expects(:exchange_code).never
    Provider::Connection.any_instance.expects(:discover_accounts!).never

    get create_oauth_callbacks_path(provider: "truelayer",
                                    code: "auth_code",
                                    state: "wrong-state")
    assert_redirected_to settings_providers_path
    assert_equal I18n.t("provider.connections.connection_failed"), flash[:alert]
  end

  test "new persists redirect_uri in connection metadata" do
    post new_oauth_callbacks_path(provider: "truelayer")
    conn = Provider::Connection.order(created_at: :desc).first
    assert_equal create_oauth_callbacks_url(provider: "truelayer"), conn.metadata["redirect_uri"]
  end
end
