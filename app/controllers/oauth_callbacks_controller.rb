class OauthCallbacksController < ApplicationController
  before_action :require_admin!

  # Session-bridged auth flow:
  #
  # No pending Provider::Connection is created at flow start. All cross-request
  # state lives in session[:provider_flows][flow_id] until the callback succeeds,
  # at which point a single Provider::Connection is created with valid tokens.
  # Failed/abandoned flows leave no DB residue.
  FLOW_TTL = 1.hour

  # POST /connect/:provider — initiates OAuth (mutates state, must not be GET).
  def new
    config = Current.family.provider_family_configs.find_by!(provider_key: params[:provider])
    redirect_uri = create_oauth_callbacks_url(provider: config.provider_key)

    flow_id = SecureRandom.hex(16)
    write_flow!(flow_id, {
      "provider_key"              => config.provider_key,
      "provider_family_config_id" => config.id,
      "redirect_uri"              => redirect_uri,
      "psu_ip"                    => public_client_ip,
      "created_at"                => Time.current.to_i
    })

    # config_for returns adapter.new(nil) — the stateless helper instance used
    # by authorize_url / scopes / token_client (no @connection required).
    adapter = Provider::ConnectionRegistry.config_for(config.provider_key)
    auth_url = adapter.authorize_url(
      client_id:    config.client_id,
      redirect_uri: redirect_uri,
      state:        flow_id,
      scope:        adapter.scopes,
      sandbox:      sandbox_for(config)
    )
    redirect_to auth_url, allow_other_host: true
  end

  # GET /connect/:provider/callback — OAuth provider redirects here.
  def create
    flow = consume_flow(params[:state])
    unless flow
      Rails.logger.warn("[OauthCallbacksController] state mismatch or expired for provider=#{params[:provider]} family=#{Current.family&.id}")
      redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
      return
    end

    config = Current.family.provider_family_configs.find(flow["provider_family_config_id"])

    # Create the connection inside a transaction. exchange_code persists tokens
    # on the connection via update!. If exchange or any other step raises, the
    # transaction rolls back and no connection survives.
    @connection = Provider::Connection.transaction do
      conn = Current.family.provider_connections.create!(
        provider_key:           flow["provider_key"],
        provider_family_config: config,
        auth_type:              "oauth2",
        status:                 :good,
        credentials:            {},
        metadata: {
          "psu_ip"       => flow["psu_ip"],
          "redirect_uri" => flow["redirect_uri"]
        }
      )
      conn.auth.exchange_code(code: params[:code])
      conn
    end

    # discover_accounts! is best-effort post-commit. If it fails the connection
    # still exists and the user can retry sync from the setup page.
    begin
      @connection.discover_accounts!
    rescue => e
      Rails.logger.warn("[OauthCallbacksController] discover_accounts! failed for connection=#{@connection.id}: #{e.class}: #{e.message}")
    end

    redirect_to setup_provider_connection_path(@connection),
                notice: t("provider.connections.connected")
  rescue Provider::Auth::TransientError => e
    Rails.logger.warn("[OauthCallbacksController] callback transient failure: #{e.class}: #{e.message}")
    redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
  rescue Provider::Truelayer::Error,
         Provider::Auth::ConsentExpiredError,
         Provider::Auth::ReauthRequiredError,
         ActiveRecord::RecordNotFound => e
    Rails.logger.warn("[OauthCallbacksController] callback failed: #{e.class}: #{e.message}")
    redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
  end

  private

    def write_flow!(flow_id, state)
      session[:provider_flows] ||= {}
      # Drop any flows older than FLOW_TTL on each write — keeps the session small.
      cutoff = FLOW_TTL.seconds.ago.to_i
      pruned = session[:provider_flows].reject { |_, v| (v.is_a?(Hash) ? v["created_at"].to_i : 0) < cutoff }
      session[:provider_flows] = pruned.merge(flow_id => state)
    end

    def consume_flow(flow_id)
      return nil if flow_id.blank?
      flows = session[:provider_flows] || {}
      flow = flows[flow_id]
      return nil unless flow.is_a?(Hash)
      return nil if flow["created_at"].to_i < FLOW_TTL.seconds.ago.to_i
      session[:provider_flows] = flows.except(flow_id)
      flow
    end

    def sandbox_for(config)
      # TrueLayer puts a `sandbox` flag on FamilyConfig.credentials. Defaults to
      # false. Future adapters that need the same can read this hash.
      config.credentials.is_a?(Hash) && (config.credentials["sandbox"] || config.credentials[:sandbox]) || false
    end

    # IPv4 carrier-grade NAT range (RFC 6598) — IPAddr#private? misses these.
    CGNAT_RANGE = IPAddr.new("100.64.0.0/10").freeze
    private_constant :CGNAT_RANGE

    # Filters out IPs that aren't public-routable. PSU IP is forwarded to
    # TrueLayer; leaking an internal/CGNAT/cloud-metadata address is a privacy
    # issue. IPAddr#private? alone misses link-local (incl. cloud metadata
    # 169.254.169.254) and CGNAT (100.64.0.0/10).
    def public_client_ip
      ip = request.remote_ip
      return nil if ip.blank?
      addr = IPAddr.new(ip)
      return nil if addr.private? || addr.loopback? || addr.link_local?
      return nil if addr.ipv4? && CGNAT_RANGE.include?(addr)
      ip
    rescue IPAddr::InvalidAddressError
      nil
    end
end
