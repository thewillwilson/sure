# Generic controller for EmbeddedLink-style auth flows (Plaid Link, MX Connect
# Widget, Yodlee FastLink, Akoya Connect — vendor-hosted modal in-page that
# returns an opaque public_token to JS, exchanged once server-side for a
# long-lived access_token).
#
# Routes (parameterized by provider_key):
#   GET  /provider_connections/:provider_key/link/new
#   GET  /provider_connections/:provider_key/link/resume?flow_id=...
#   POST /provider_connections/:provider_key/link/callback
#
# Provider-specific work is delegated to the adapter via the
# Provider::ConnectionAdapter EmbeddedLink contract:
#   - .start_link_flow(family:, flow_id:, params:, resume_url:, webhooks_url:)
#   - .complete_link_flow(family:, flow:, params:)
#   - .js_controller_name
#   - .js_data_for(flow:, is_resume:)
#
# Cross-request flow state lives in session[:provider_flows] (see
# ProviderAuthFlowSession concern). No Provider::Connection is created until
# #create completes the exchange with valid credentials.
class EmbeddedLinkCallbacksController < ApplicationController
  include ProviderAuthFlowSession

  before_action :require_admin!
  before_action :resolve_adapter!

  def new
    flow_id = SecureRandom.hex(16)
    flow = @adapter.start_link_flow(
      family:       Current.family,
      flow_id:      flow_id,
      params:       params,
      resume_url:   resume_embedded_link_callbacks_url(provider_key: provider_key, flow_id: flow_id),
      webhooks_url: webhooks_provider_url(provider_key: provider_key)
    )
    write_flow!(flow_id, flow)
    render_link_view(flow_id: flow_id, flow: flow, is_resume: false)
  rescue ArgumentError => e
    Rails.logger.warn("[EmbeddedLinkCallbacksController] #{provider_key}#new rejected: #{e.message}")
    head :bad_request
  end

  def resume
    flow = peek_flow(params[:flow_id])
    unless flow
      redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
      return
    end
    render_link_view(flow_id: params[:flow_id], flow: flow, is_resume: true)
  end

  def create
    flow = consume_flow(params[:flow_id])
    unless flow
      Rails.logger.warn("[EmbeddedLinkCallbacksController] #{provider_key} flow expired/missing for family=#{Current.family&.id}")
      redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
      return
    end

    @connection = @adapter.complete_link_flow(family: Current.family, flow: flow, params: params)

    begin
      @connection.discover_accounts!
    rescue => e
      Rails.logger.warn("[EmbeddedLinkCallbacksController] discover_accounts! failed for connection=#{@connection.id}: #{e.class}: #{e.message}")
    end

    redirect_to setup_provider_connection_path(@connection),
                notice: t("provider.connections.connected")
  rescue => e
    Rails.logger.warn("[EmbeddedLinkCallbacksController] #{provider_key}#create failed: #{e.class}: #{e.message}")
    redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
  end

  private

    def provider_key
      params[:provider_key].to_s
    end

    def resolve_adapter!
      @adapter = Provider::ConnectionRegistry.adapter_for(provider_key)
      unless @adapter.auth_class == Provider::Auth::EmbeddedLink
        head :not_found
      end
    rescue NotImplementedError
      head :not_found
    end

    def render_link_view(flow_id:, flow:, is_resume:)
      # Hand flow_id into the flow Hash so the adapter's js_data_for can include it.
      flow_with_id = flow.merge("__flow_id" => flow_id)
      @js_data = @adapter.js_data_for(flow: flow_with_id, is_resume: is_resume)
      render :new
    end
end
