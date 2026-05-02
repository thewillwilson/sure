class Provider::Truelayer
  include HTTParty
  extend SslConfigurable

  PRODUCTION_AUTH_BASE = "https://auth.truelayer.com".freeze
  SANDBOX_AUTH_BASE    = "https://auth.truelayer-sandbox.com".freeze
  PRODUCTION_API_BASE  = "https://api.truelayer.com/data/v1".freeze
  SANDBOX_API_BASE     = "https://api.truelayer-sandbox.com/data/v1".freeze

  SCOPES      = "accounts cards balance transactions offline_access".freeze
  MAX_RETRIES = 3
  SANDBOX_PROVIDERS    = "mock".freeze
  PRODUCTION_PROVIDERS = "uk-oauth-all,uk-ob-all,ie-ob-all,de-xe-all,fr-xe-all,es-xe-all".freeze

  headers "User-Agent" => "Sure Finance TrueLayer Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :client_id, :client_secret, :access_token, :sandbox

  def initialize(client_id:, client_secret:, access_token: nil, sandbox: false)
    @client_id     = client_id
    @client_secret = client_secret
    @access_token  = access_token
    @sandbox       = sandbox
  end

  def auth_url(redirect_uri:, state:)
    params = {
      response_type: "code",
      client_id:     client_id,
      scope:         SCOPES,
      redirect_uri:  redirect_uri,
      state:         state,
      providers:     sandbox ? SANDBOX_PROVIDERS : PRODUCTION_PROVIDERS
    }
    "#{auth_base}/?#{params.to_query}"
  end

  def exchange_code(code:, redirect_uri:)
    response = self.class.post(
      "#{auth_base}/connect/token",
      headers: { "Content-Type" => "application/x-www-form-urlencoded" },
      body: {
        grant_type:    "authorization_code",
        client_id:     client_id,
        client_secret: client_secret,
        code:          code,
        redirect_uri:  redirect_uri
      }
    )
    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  def refresh_access_token(refresh_token:)
    response = self.class.post(
      "#{auth_base}/connect/token",
      headers: { "Content-Type" => "application/x-www-form-urlencoded" },
      body: {
        grant_type:    "refresh_token",
        client_id:     client_id,
        client_secret: client_secret,
        refresh_token: refresh_token
      }
    )
    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  def generate_reauth_uri(refresh_token:, redirect_uri:, state: nil)
    body = {
      response_type: "code",
      refresh_token:  refresh_token,
      redirect_uri:   redirect_uri
    }
    body[:state] = state if state.present?

    response = self.class.post(
      "#{auth_base}/v1/reauthuri",
      headers: { "Content-Type" => "application/json" },
      body:    body.to_json
    )
    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  def get_me(psu_ip: nil)
    with_rate_limit_retry do
      response = self.class.get(
        "#{api_base}/me",
        headers: bearer_headers(psu_ip: psu_ip)
      )
      extract_results(handle_response(response)).first
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  def get_accounts(psu_ip: nil)
    with_rate_limit_retry do
      response = self.class.get(
        "#{api_base}/accounts",
        headers: bearer_headers(psu_ip: psu_ip)
      )
      extract_results(handle_response(response))
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  def get_cards(psu_ip: nil)
    with_rate_limit_retry do
      response = self.class.get(
        "#{api_base}/cards",
        headers: bearer_headers(psu_ip: psu_ip)
      )
      extract_results(handle_response(response))
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  def get_balance(account_id:, kind:, psu_ip: nil)
    with_rate_limit_retry do
      path = kind == "card" ? "cards" : "accounts"
      response = self.class.get(
        "#{api_base}/#{path}/#{account_id}/balance",
        headers: bearer_headers(psu_ip: psu_ip)
      )
      extract_results(handle_response(response)).first
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  def get_transactions(account_id:, kind:, from: nil, to: nil, psu_ip: nil)
    with_rate_limit_retry do
      path = kind == "card" ? "cards" : "accounts"
      query = {}
      query[:from] = from.to_date.iso8601 if from
      query[:to]   = to.to_date.iso8601   if to

      response = self.class.get(
        "#{api_base}/#{path}/#{account_id}/transactions",
        headers: bearer_headers(psu_ip: psu_ip),
        query:   query.presence
      )
      extract_results(handle_response(response))
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  def get_pending_transactions(account_id:, kind:, psu_ip: nil)
    with_rate_limit_retry do
      path = kind == "card" ? "cards" : "accounts"
      response = self.class.get(
        "#{api_base}/#{path}/#{account_id}/transactions/pending",
        headers: bearer_headers(psu_ip: psu_ip)
      )
      extract_results(handle_response(response))
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise TruelayerError.new("Request failed: #{e.message}", :request_failed)
  end

  private

    def auth_base
      sandbox ? SANDBOX_AUTH_BASE : PRODUCTION_AUTH_BASE
    end

    def api_base
      sandbox ? SANDBOX_API_BASE : PRODUCTION_API_BASE
    end

    def bearer_headers(psu_ip: nil)
      headers = {
        "Authorization" => "Bearer #{access_token}",
        "Accept"        => "application/json"
      }
      headers["X-PSU-IP"] = psu_ip if psu_ip.present?
      headers
    end

    def extract_results(parsed)
      parsed[:results] || parsed["results"] || []
    end

    def handle_response(response)
      case response.code
      when 200, 201
        parse_body(response)
      when 400
        raise TruelayerError.new("Bad request: #{response.body.to_s.truncate(200)}", :bad_request)
      when 401
        raise TruelayerError.new("Unauthorized — token may be expired", :unauthorized)
      when 403
        body = response.body.to_s
        error_type = body.include?("sca_exceeded") ? :sca_exceeded : :forbidden
        raise TruelayerError.new("Forbidden (#{error_type}): #{body.truncate(200)}", error_type)
      when 404
        raise TruelayerError.new("Not found", :not_found)
      when 429
        retry_after = response.headers["Retry-After"]&.to_i
        raise TruelayerError.new("Rate limit exceeded", :rate_limited, retry_after: retry_after)
      when 501
        raise TruelayerError.new("Endpoint not supported by this provider", :not_implemented)
      else
        raise TruelayerError.new("Unexpected response #{response.code}: #{response.body.to_s.truncate(200)}", :fetch_failed)
      end
    end

    def parse_body(response)
      return {} if response.body.blank?
      JSON.parse(response.body, symbolize_names: true, decimal_class: BigDecimal)
    rescue JSON::ParserError => e
      Rails.logger.error "TrueLayer API: Failed to parse response: #{e.message}"
      raise TruelayerError.new("Failed to parse response: #{e.message}", :parse_error)
    end

    def with_rate_limit_retry(max_retries: MAX_RETRIES)
      attempts = 0
      begin
        yield
      rescue TruelayerError => e
        raise unless e.error_type == :rate_limited
        attempts += 1
        raise if attempts >= max_retries
        wait = e.retry_after.to_i
        if wait > 0
          Rails.logger.warn "TrueLayer: rate limited, sleeping #{wait}s before retry (attempt #{attempts}/#{max_retries})"
          sleep(wait)
        else
          Rails.logger.warn "TrueLayer: rate limited, retrying (attempt #{attempts}/#{max_retries})"
        end
        retry
      end
    end

    class TruelayerError < StandardError
      attr_reader :error_type, :retry_after

      def initialize(message, error_type = :unknown, retry_after: nil)
        super(message)
        @error_type  = error_type
        @retry_after = retry_after
      end
    end
end
