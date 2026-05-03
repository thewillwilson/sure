class Provider::Account < ApplicationRecord
  include Encryptable

  self.table_name = "provider_accounts"

  belongs_to :provider_connection, class_name: "Provider::Connection"
  belongs_to :account, optional: true

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_holdings_payload
    encrypts :raw_liabilities_payload
  end

  scope :unlinked_and_unskipped, -> { where(account_id: nil, skipped: false) }

  validates :external_id, uniqueness: { scope: :provider_connection_id }

  class UnsupportedAccountableType < StandardError; end

  def linked? = account_id?

  # Logo URL extracted from the upstream provider payload. Restricted to HTTPS
  # to prevent mixed-content + downgrade tracking-pixel risks when rendered
  # into authenticated pages.
  def safe_logo_uri
    raw = raw_payload&.dig("provider", "logo_uri")
    return nil if raw.blank?
    URI.parse(raw).is_a?(URI::HTTPS) ? raw : nil
  rescue URI::InvalidURIError
    nil
  end

  # Delegates to the adapter so each provider owns its own external_type →
  # Accountable mapping (and any per-type customisation, e.g. investments
  # building Holdings). Adapters raise UnsupportedAccountableType for types
  # they don't handle, rather than silently mis-categorising.
  def build_sure_account(family:)
    Provider::ConnectionRegistry
      .adapter_for(provider_connection.provider_key)
      .build_sure_account(self, family: family)
  end
end
