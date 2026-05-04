# Plaid Link is an embedded JS widget — distinct from OAuth2 redirect grants.
#
# Session-bridged flow (see ProviderAuthFlowSession concern):
#
#   1. GET  /provider_connections/plaid/new?region=us
#        → server creates a link_token, stashes it in session keyed by flow_id,
#          renders an HTML page that mounts the JS controller with link_token
#          + flow_id.
#
#   2. (Standard non-OAuth bank): JS opens Plaid Link → user enters credentials
#      → onSuccess returns public_token → JS POSTs to #create with flow_id +
#      public_token.
#
#   3. (OAuth bank only): JS opens Plaid Link → user picks Chase → Plaid
#      redirects browser to redirect_url (= /provider_connections/plaid/resume)
#      → #resume re-renders the page using the SAME link_token from session,
#      signalling JS to resume the modal with receivedRedirectUri → modal
#      completes → onSuccess → POST to #create.
#
#   4. POST /provider_connections/plaid/callback
#        → server consumes the flow, exchanges public_token for access_token,
#          creates the Provider::Connection, runs discover_accounts!, redirects
#          to setup.
#
# No Provider::Connection is created at flow start. The only DB row is the real
# Provider::Connection created at #create when a valid access_token exists.
#
# Update mode (reauth): #new accepts connection_id instead of region. The
# link_token is created with the existing access_token; on success JS triggers
# a sync rather than POSTing a new public_token.
class PlaidLinkCallbacksController < ApplicationController
  include ProviderAuthFlowSession

  before_action :require_admin!

  def new
    if params[:connection_id].present?
      build_update_flow
    else
      build_new_flow
    end
  end

  # GET /provider_connections/plaid/resume?flow_id=...&oauth_state_id=...
  # Plaid OAuth-bank redirect lands here; we re-render with the persisted link_token.
  def resume
    flow = peek_flow(params[:flow_id])
    unless flow
      redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
      return
    end
    @flow_id    = params[:flow_id]
    @link_token = flow["link_token"]
    @region     = flow["region"]
    @is_update  = flow["kind"] == "update"
    @is_resume  = true
    render :new
  end

  # POST /provider_connections/plaid/callback
  def create
    flow = consume_flow(params[:flow_id])
    unless flow
      Rails.logger.warn("[PlaidLinkCallbacksController] flow expired/missing for family=#{Current.family&.id}")
      redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
      return
    end

    region = flow["region"]
    response = plaid_client(region).exchange_public_token(params.require(:public_token))

    @connection = Provider::Connection.transaction do
      conn = Current.family.provider_connections.create!(
        provider_key: "plaid_#{region}",
        auth_type:    "embedded_link",
        status:       :good,
        credentials:  {},
        metadata: {
          "region"        => region,
          "plaid_item_id" => response.item_id
        }
      )
      conn.auth.store_access_token(response.access_token)
      conn
    end

    begin
      @connection.discover_accounts!
    rescue => e
      Rails.logger.warn("[PlaidLinkCallbacksController] discover_accounts! failed for connection=#{@connection.id}: #{e.class}: #{e.message}")
    end

    redirect_to setup_provider_connection_path(@connection),
                notice: t("provider.connections.connected")
  rescue => e
    Rails.logger.warn("[PlaidLinkCallbacksController] callback failed: #{e.class}: #{e.message}")
    redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
  end

  private

    VALID_REGIONS = %w[us eu].freeze

    def build_new_flow
      region = params[:region].to_s
      unless VALID_REGIONS.include?(region)
        head :bad_request
        return
      end

      issue_link_token!(region: region, kind: "new")
    end

    def build_update_flow
      @connection = Current.family.provider_connections.find(params[:connection_id])
      issue_link_token!(
        region: @connection.metadata["region"],
        kind:   "update",
        access_token: @connection.credentials["access_token"]
      )
    end

    # Single point of link_token issuance + session persistence — used by both
    # new and update flows. Plaid's get_link_token signature handles both via
    # the optional access_token kwarg (presence triggers update mode upstream).
    def issue_link_token!(region:, kind:, access_token: nil)
      flow_id = SecureRandom.hex(16)
      link_token = plaid_client(region).get_link_token(
        user_id:          Current.family.id,
        webhooks_url:     webhooks_provider_url(provider_key: "plaid_#{region}"),
        redirect_url:     resume_plaid_link_callbacks_url(flow_id: flow_id),
        accountable_type: params[:accountable_type],
        access_token:     access_token
      ).link_token

      flow_state = {
        "kind"       => kind,
        "region"     => region,
        "link_token" => link_token,
        "created_at" => Time.current.to_i
      }
      flow_state["connection_id"] = @connection.id if kind == "update"
      write_flow!(flow_id, flow_state)

      @flow_id    = flow_id
      @link_token = link_token
      @region     = region
      @is_update  = kind == "update"
      @is_resume  = false
    end

    def plaid_client(region)
      Provider::Registry.plaid_provider_for_region(region.to_sym)
    end
end
