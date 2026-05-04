require "test_helper"

class OauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  FAKE_AUTH_URL = "https://auth.truelayer.com/?response_type=code&client_id=test"

  setup do
    sign_in users(:family_admin)
    provider_family_configs(:truelayer_family_one)
    # Stub the stateless adapter helper used by #new — authorize_url is called
    # on the adapter (TruelayerAdapter) directly, not on Provider::Auth::OAuth2.
    Provider::TruelayerAdapter.any_instance.stubs(:authorize_url).returns(FAKE_AUTH_URL)
  end

  test "new redirects to TrueLayer auth URL" do
    post new_oauth_callbacks_path(provider: "truelayer")
    assert_response :redirect
    assert_match "auth.truelayer.com", response.location
  end

  test "new does NOT create a Provider::Connection (flow state lives in session)" do
    assert_no_difference "Provider::Connection.count" do
      post new_oauth_callbacks_path(provider: "truelayer")
    end
  end

  test "new stashes flow state in session under a flow_id" do
    post new_oauth_callbacks_path(provider: "truelayer")
    flows = session[:provider_flows]
    assert flows.is_a?(Hash) && flows.any?
    flow = flows.values.first
    assert_equal "truelayer", flow["provider_key"]
    assert_kind_of Integer, flow["created_at"]
  end

  test "new stores psu_ip in flow state when client IP is public" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "203.0.113.42" }
    flow = session[:provider_flows].values.first
    assert_equal "203.0.113.42", flow["psu_ip"]
  end

  test "new omits psu_ip when client IP is private or loopback" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "127.0.0.1" }
    flow = session[:provider_flows].values.first
    assert_nil flow["psu_ip"]
  end

  test "new omits psu_ip for CGNAT (100.64.0.0/10) addresses" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "100.64.1.42" }
    flow = session[:provider_flows].values.first
    assert_nil flow["psu_ip"]
  end

  test "new omits psu_ip for IPv4 link-local (cloud metadata) addresses" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "169.254.169.254" }
    flow = session[:provider_flows].values.first
    assert_nil flow["psu_ip"]
  end

  test "new omits psu_ip for IPv6 link-local addresses" do
    post new_oauth_callbacks_path(provider: "truelayer"),
         headers: { "REMOTE_ADDR" => "fe80::1" }
    flow = session[:provider_flows].values.first
    assert_nil flow["psu_ip"]
  end

  test "new persists redirect_uri in flow state" do
    post new_oauth_callbacks_path(provider: "truelayer")
    flow = session[:provider_flows].values.first
    assert_equal create_oauth_callbacks_url(provider: "truelayer"), flow["redirect_uri"]
  end

  test "create exchanges code, creates connection, redirects to setup" do
    post new_oauth_callbacks_path(provider: "truelayer")
    flow_id = session[:provider_flows].keys.first

    Provider::Auth::OAuth2.any_instance.expects(:exchange_code).once
    Provider::Connection.any_instance.expects(:discover_accounts!).once

    assert_difference "Provider::Connection.count", 1 do
      get create_oauth_callbacks_path(provider: "truelayer",
                                      code: "auth_code",
                                      state: flow_id)
    end
    conn = Provider::Connection.order(created_at: :desc).first
    assert_redirected_to setup_provider_connection_path(conn)
    assert_equal "truelayer", conn.provider_key
    assert conn.good?
    # Flow consumed from session.
    assert_nil session[:provider_flows][flow_id]
  end

  test "create rejects unknown state without creating a connection" do
    Provider::Auth::OAuth2.any_instance.expects(:exchange_code).never

    assert_no_difference "Provider::Connection.count" do
      get create_oauth_callbacks_path(provider: "truelayer",
                                      code: "auth_code",
                                      state: "unknown-flow-id")
    end
    assert_redirected_to settings_providers_path
    assert_equal I18n.t("provider.connections.connection_failed"), flash[:alert]
  end

  test "create with already-consumed flow_id rejects (no replay)" do
    post new_oauth_callbacks_path(provider: "truelayer")
    flow_id = session[:provider_flows].keys.first

    Provider::Auth::OAuth2.any_instance.stubs(:exchange_code)
    Provider::Connection.any_instance.stubs(:discover_accounts!)

    # First callback consumes the flow
    get create_oauth_callbacks_path(provider: "truelayer", code: "code1", state: flow_id)
    # Replay attempt with the same flow_id
    assert_no_difference "Provider::Connection.count" do
      get create_oauth_callbacks_path(provider: "truelayer", code: "code2", state: flow_id)
    end
    assert_redirected_to settings_providers_path
  end
end
