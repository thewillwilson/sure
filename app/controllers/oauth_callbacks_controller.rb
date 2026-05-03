class OauthCallbacksController < ApplicationController
  before_action :require_admin!

  # POST /connect/:provider — initiates OAuth (mutates state, must not be GET).
  def new
    config = Current.family.provider_family_configs.find_by!(provider_key: params[:provider])
    Current.family.provider_connections.where(provider_family_config: config, status: :pending).destroy_all
    redirect_uri = create_oauth_callbacks_url(provider: config.provider_key)
    connection = Current.family.provider_connections.create!(
      provider_key:           config.provider_key,
      provider_family_config: config,
      auth_type:              "oauth2",
      status:                 :pending,
      metadata:               {
        "psu_ip"       => public_client_ip,
        "redirect_uri" => redirect_uri
      }
    )
    session[:oauth_state] = connection.id
    auth = Provider::Auth::OAuth2.new(connection)
    redirect_to auth.authorize_url(
      redirect_uri: redirect_uri,
      state:        connection.id
    ), allow_other_host: true
  end

  # GET /connect/:provider/callback — OAuth provider redirects here.
  def create
    expected_state = session.delete(:oauth_state)
    if expected_state.blank? || params[:state] != expected_state
      Rails.logger.warn("[OauthCallbacksController] state mismatch for provider=#{params[:provider]} family=#{Current.family&.id}")
      redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
      return
    end

    connection = Current.family.provider_connections.find(params[:state])
    auth = Provider::Auth::OAuth2.new(connection)
    auth.exchange_code(code: params[:code])
    connection.discover_accounts!
    redirect_to setup_provider_connection_path(connection),
                notice: t("provider.connections.connected")
  rescue Provider::Auth::TransientError => e
    # Transient (network/5xx). exchange_code may have already stored valid tokens;
    # don't disconnect — let the user retry the callback or re-sync later.
    Rails.logger.warn("[OauthCallbacksController] callback transient failure: #{e.class}: #{e.message}")
    redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
  rescue Provider::Truelayer::Error,
         Provider::Auth::ConsentExpiredError,
         Provider::Auth::ReauthRequiredError,
         ActiveRecord::RecordNotFound => e
    Rails.logger.warn("[OauthCallbacksController] callback failed: #{e.class}: #{e.message}")
    connection&.update!(status: :disconnected, sync_error: e.class.name.demodulize.underscore)
    redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
  end

  private

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
