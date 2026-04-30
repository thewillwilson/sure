require "test_helper"

class Provider::TruelayerTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Truelayer.new(
      client_id: "test_client_id",
      client_secret: "test_secret",
      access_token: "test_token"
    )
    @sandbox_provider = Provider::Truelayer.new(
      client_id: "sandbox_client_id",
      client_secret: "sandbox_secret",
      access_token: "sandbox_token",
      sandbox: true
    )
  end

  test "builds correct auth url for production" do
    url = @provider.auth_url(redirect_uri: "https://example.com/callback", state: "item_123")
    assert_includes url, "https://auth.truelayer.com/"
    assert_includes url, "client_id=test_client_id"
    assert_includes url, "state=item_123"
    assert_includes url, "offline_access"
  end

  test "builds correct auth url for sandbox" do
    url = @sandbox_provider.auth_url(redirect_uri: "https://example.com/callback", state: "item_123")
    assert_includes url, "https://auth.truelayer-sandbox.com/"
  end

  test "raises TruelayerError on 401" do
    stub_request(:get, "https://api.truelayer.com/data/v1/accounts")
      .to_return(status: 401, body: '{"error":"unauthorized"}', headers: { "Content-Type" => "application/json" })

    assert_raises(Provider::Truelayer::TruelayerError) do
      @provider.get_accounts
    end
  end

  test "error message truncates long response body to 200 chars" do
    stub_request(:get, /api\.truelayer\.com/)
      .to_return(status: 400, body: "x" * 500, headers: {})

    error = assert_raises(Provider::Truelayer::TruelayerError) do
      @provider.get_accounts
    end

    assert error.message.length <= 230, "error message should not include full response body"
  end

  test "retries on 429 and succeeds on second attempt" do
    stub_request(:get, "https://api.truelayer.com/data/v1/accounts")
      .to_return(
        { status: 429, body: "", headers: { "Retry-After" => "0" } },
        { status: 200, body: { results: [] }.to_json, headers: { "Content-Type" => "application/json" } }
      )

    result = @provider.get_accounts
    assert_equal [], result
    assert_requested :get, "https://api.truelayer.com/data/v1/accounts", times: 2
  end

  test "raises TruelayerError after exhausting retries on 429" do
    stub_request(:get, "https://api.truelayer.com/data/v1/accounts")
      .to_return(status: 429, body: "", headers: { "Retry-After" => "0" })

    error = assert_raises(Provider::Truelayer::TruelayerError) do
      @provider.get_accounts
    end

    assert_equal :rate_limited, error.error_type
    assert_requested :get, "https://api.truelayer.com/data/v1/accounts", times: 3
  end

  test "includes X-PSU-IP header in API requests when psu_ip is provided" do
    stub_request(:get, "https://api.truelayer.com/data/v1/accounts")
      .with(headers: { "X-PSU-IP" => "203.0.113.42" })
      .to_return(status: 200, body: { results: [] }.to_json, headers: { "Content-Type" => "application/json" })

    result = @provider.get_accounts(psu_ip: "203.0.113.42")

    assert_equal [], result
    assert_requested :get, "https://api.truelayer.com/data/v1/accounts",
      headers: { "X-PSU-IP" => "203.0.113.42" }
  end

  test "omits X-PSU-IP header when psu_ip is blank" do
    stub_request(:get, "https://api.truelayer.com/data/v1/accounts")
      .to_return(status: 200, body: { results: [] }.to_json, headers: { "Content-Type" => "application/json" })

    @provider.get_accounts(psu_ip: nil)

    assert_not_requested :get, "https://api.truelayer.com/data/v1/accounts",
      headers: { "X-PSU-IP" => /.*/ }
  end
end
