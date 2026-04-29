module TruelayerItem::Provided
  extend ActiveSupport::Concern

  def truelayer_provider
    return nil unless credentials_configured?

    Provider::Truelayer.new(
      client_id:     client_id,
      client_secret: client_secret,
      access_token:  access_token,
      sandbox:       sandbox?
    )
  end

  def credentials_configured?
    client_id.present? && client_secret.present?
  end

  def token_valid?
    access_token.present? && (token_expires_at.nil? || token_expires_at > 30.seconds.from_now)
  end

  def token_expired?
    access_token.present? && token_expires_at.present? && token_expires_at <= 30.seconds.from_now
  end

  def token_lapsed?
    access_token.present? && token_expires_at.present? && token_expires_at <= Time.current
  end

  def refresh_tokens!
    with_lock do
      provider = Provider::Truelayer.new(
        client_id:     client_id,
        client_secret: client_secret,
        sandbox:       sandbox?
      )
      result = provider.refresh_access_token(refresh_token: refresh_token)
      update!(
        access_token:     result[:access_token],
        refresh_token:    result[:refresh_token] || refresh_token,
        token_expires_at: Time.current + result[:expires_in].to_i.seconds,
        status:           :good
      )
    end
  rescue Provider::Truelayer::TruelayerError => e
    if [ :unauthorized, :bad_request ].include?(e.error_type) || e.message.include?("invalid_grant")
      update!(status: :requires_update)
      raise StandardError.new("TrueLayer token expired — re-authorization required")
    end
    raise
  end
end
