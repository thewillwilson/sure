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
  # GET /provider_connections/plaid/new?connection_id=:id   (reauth/update mode)
  #
  # Renders an HTML page that mounts the JS controller. New flow: opens Plaid
  # Link with a fresh link_token and POSTs public_token to #create. Update flow
  # (when connection_id is present): passes the existing access_token to Plaid
  # so Link opens in UPDATE mode; on success the JS controller triggers a sync
  # against the existing Provider::Connection.
  def new
    @region     = region
    if params[:connection_id].present?
      @connection = Current.family.provider_connections.find(params[:connection_id])
      @region = @connection.metadata["region"]
      @is_update = true
      @link_token = plaid_client.get_link_token(
        user_id:          Current.family.id,
        webhooks_url:     webhooks_url,
        redirect_url:     create_plaid_link_callbacks_url,
        access_token:     @connection.credentials["access_token"]
      ).link_token
    else
      @is_update = false
      @link_token = Current.family.get_link_token(
        webhooks_url:     webhooks_url,
        redirect_url:     create_plaid_link_callbacks_url,
        accountable_type: params[:accountable_type],
        region:           region.to_sym
      )
    end
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
      # Update mode reads region from the connection.metadata; new mode reads from params.
      if params[:connection_id].present?
        Current.family.provider_connections.find_by(id: params[:connection_id])&.metadata&.[]("region").to_s
      else
        params[:region].to_s
      end
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
