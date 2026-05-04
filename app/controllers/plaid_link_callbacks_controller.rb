# Plaid Link is an embedded JS widget — distinct from OAuth2 redirect grants.
# Flow:
#   1. GET /provider_connections/plaid/link_token (this#new) returns a fresh
#      Plaid link_token JSON; client JS opens Plaid Link with it.
#   2. User completes Plaid Link, JS receives a public_token via onSuccess
#      callback, POSTs it to this#create.
#   3. We exchange public_token for a permanent access_token, create a
#      Provider::Connection storing that access_token via EmbeddedLink, and
#      run discover_accounts! so provider_accounts populate.
#
# This is NOT in OauthCallbacksController because Plaid Link is not OAuth2 —
# no redirect, no state param, no code exchange. The flows share zero
# state-handling logic.
class PlaidLinkCallbacksController < ApplicationController
  before_action :require_admin!
  before_action :validate_region

  # GET /provider_connections/plaid/new?region=us
  # Renders an HTML page that mounts the JS controller; the controller opens
  # Plaid Link with the link_token and POSTs the resulting public_token to #create.
  def new
    @region     = region
    @link_token = Current.family.get_link_token(
      webhooks_url:     webhooks_url,
      redirect_url:     create_plaid_link_callbacks_url,
      accountable_type: params[:accountable_type],
      region:           region.to_sym
    )
  end

  # POST /provider_connections/plaid/callback
  def create
    response = plaid_client.exchange_public_token(params.require(:public_token))

    connection = Current.family.provider_connections.create!(
      provider_key: "plaid_#{region}",
      auth_type:    "embedded_link",
      status:       :pending,
      credentials:  {},
      metadata:     {
        "region"        => region,
        "plaid_item_id" => response.item_id
      }
    )
    connection.auth.store_access_token(response.access_token)
    connection.discover_accounts!

    redirect_to setup_provider_connection_path(connection),
                notice: t("provider.connections.connected")
  rescue => e
    Rails.logger.warn("[PlaidLinkCallbacksController] callback failed: #{e.class}: #{e.message}")
    redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
  end

  private

    def region
      params[:region].to_s
    end

    def validate_region
      return if %w[us eu].include?(region)
      head :bad_request
    end

    def plaid_client
      Provider::Registry.plaid_provider_for_region(region.to_sym)
    end

    def webhooks_url
      # New generic webhook endpoint will arrive in Phase 4. Until then,
      # the existing per-region URLs are still valid; the webhook controller
      # routes by plaid_item_id which we now also store on connection.metadata,
      # so the Phase 4 shim can resolve either way.
      if region == "eu"
        Rails.env.production? ? webhooks_plaid_eu_url : ENV.fetch("DEV_WEBHOOKS_URL", root_url.chomp("/")) + "/webhooks/plaid_eu"
      else
        Rails.env.production? ? webhooks_plaid_url : ENV.fetch("DEV_WEBHOOKS_URL", root_url.chomp("/")) + "/webhooks/plaid"
      end
    end
end
