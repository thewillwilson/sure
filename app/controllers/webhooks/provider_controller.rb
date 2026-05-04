# Generic webhook receiver for Provider::Connection adapters.
#
# Routes:
#   POST /webhooks/providers/:provider_key
#
# Responsibilities are deliberately minimal — verify the signature via the
# adapter, instantiate the adapter's webhook_handler_class, dispatch. All
# provider-specific logic (signature scheme, payload parsing, event handling)
# lives on the adapter, not in this controller.
#
# Always returns 200 unless the signature itself is invalid; handler exceptions
# are captured to Sentry inside the handler so a single bad payload doesn't
# disable the endpoint.
class Webhooks::ProviderController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  def receive
    adapter = Provider::ConnectionRegistry.adapter_for(params[:provider_key])
    raw_body = request.body.read

    adapter.verify_webhook!(headers: request.headers, raw_body: raw_body)
    adapter.webhook_handler_class.new(raw_body: raw_body, headers: request.headers).process

    render json: { received: true }, status: :ok
  rescue NotImplementedError => e
    Sentry.capture_exception(e)
    render json: { error: "Provider does not accept webhooks" }, status: :bad_request
  rescue => e
    Sentry.capture_exception(e)
    Rails.logger.error("[Webhooks::ProviderController] #{params[:provider_key]} verification failed: #{e.class}: #{e.message}")
    render json: { error: "Invalid webhook" }, status: :bad_request
  end
end
