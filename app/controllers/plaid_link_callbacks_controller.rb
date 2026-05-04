# Plaid Link is an embedded JS widget — distinct from OAuth2 redirect grants.
#
# Session-bridged flow:
#
#   1. GET  /provider_connections/plaid/new?region=us
#        → server creates a link_token, stashes it in session keyed by flow_id,
#          renders an HTML page that mounts the JS controller with link_token + flow_id.
#
#   2. (Standard non-OAuth bank): JS opens Plaid Link → user enters credentials →
#      onSuccess returns public_token → JS POSTs to #create with flow_id + public_token.
#
#   3. (OAuth bank only): JS opens Plaid Link → user picks Chase →
#      Plaid redirects browser to redirect_url (= /provider_connections/plaid/resume) →
#      #resume re-renders the page using the SAME link_token from session, signalling
#      JS to resume the modal with receivedRedirectUri → modal completes →
#      onSuccess → POST to #create.
#
#   4. POST /provider_connections/plaid/callback
#        → server consumes the flow, exchanges public_token for access_token,
#          creates the Provider::Connection, runs discover_accounts!, redirects to setup.
#
# No pending Provider::Connection is created at flow start. The only DB row is the
# real Provider::Connection created at #create when a valid access_token exists.
#
# Update mode (reauth): #new accepts connection_id instead of region. The link_token
# is created with the existing access_token; on success JS triggers a sync rather
# than POSTing a new public_token.
class PlaidLinkCallbacksController < ApplicationController
  before_action :require_admin!

  FLOW_TTL = 1.hour

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

    def build_new_flow
      region = params[:region].to_s
      unless %w[us eu].include?(region)
        head :bad_request
        return
      end

      flow_id = SecureRandom.hex(16)
      link_token = Current.family.get_link_token(
        webhooks_url:     webhooks_url(region),
        redirect_url:     resume_plaid_link_callbacks_url(flow_id: flow_id),
        accountable_type: params[:accountable_type],
        region:           region.to_sym
      )

      write_flow!(flow_id, {
        "kind"       => "new",
        "region"     => region,
        "link_token" => link_token,
        "created_at" => Time.current.to_i
      })

      @flow_id    = flow_id
      @link_token = link_token
      @region     = region
      @is_update  = false
      @is_resume  = false
    end

    def build_update_flow
      @connection = Current.family.provider_connections.find(params[:connection_id])
      region = @connection.metadata["region"]
      flow_id = SecureRandom.hex(16)

      link_token = plaid_client(region).get_link_token(
        user_id:      Current.family.id,
        webhooks_url: webhooks_url(region),
        redirect_url: resume_plaid_link_callbacks_url(flow_id: flow_id),
        access_token: @connection.credentials["access_token"]
      ).link_token

      write_flow!(flow_id, {
        "kind"          => "update",
        "region"        => region,
        "link_token"    => link_token,
        "connection_id" => @connection.id,
        "created_at"    => Time.current.to_i
      })

      @flow_id    = flow_id
      @link_token = link_token
      @region     = region
      @is_update  = true
      @is_resume  = false
    end

    def write_flow!(flow_id, state)
      session[:provider_flows] ||= {}
      cutoff = FLOW_TTL.seconds.ago.to_i
      pruned = session[:provider_flows].reject { |_, v| (v.is_a?(Hash) ? v["created_at"].to_i : 0) < cutoff }
      session[:provider_flows] = pruned.merge(flow_id => state)
    end

    def peek_flow(flow_id)
      return nil if flow_id.blank?
      flow = session[:provider_flows]&.dig(flow_id)
      return nil unless flow.is_a?(Hash)
      return nil if flow["created_at"].to_i < FLOW_TTL.seconds.ago.to_i
      flow
    end

    def consume_flow(flow_id)
      flow = peek_flow(flow_id)
      return nil unless flow
      session[:provider_flows] = (session[:provider_flows] || {}).except(flow_id)
      flow
    end

    def plaid_client(region)
      Provider::Registry.plaid_provider_for_region(region.to_sym)
    end

    def webhooks_url(region)
      # Generic provider-webhooks endpoint. The legacy /webhooks/plaid endpoint
      # was removed in the cutover.
      url_for(controller: "webhooks/provider", action: "receive",
              provider_key: "plaid_#{region}", only_path: false)
    end
end
