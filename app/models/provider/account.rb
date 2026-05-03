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

  # When migrating a new adapter onto this framework, extend ACCOUNTABLE_MAP
  # with the new external_type → Accountable subclass mapping. The fallback
  # raises rather than silently mis-categorizing (e.g., putting investment
  # accounts into Depository), which would corrupt financial data.
  ACCOUNTABLE_MAP = {
    "depository" => Depository,
    "credit"     => CreditCard
  }.freeze

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

  def build_sure_account(family:)
    accountable_class = ACCOUNTABLE_MAP[external_type.to_s] ||
      raise(UnsupportedAccountableType,
            "Provider::Account #{id || '(unsaved)'} has external_type=#{external_type.inspect} " \
            "which is not in ACCOUNTABLE_MAP. Extend the map when adding a new adapter.")
    accountable = accountable_class.new(subtype: external_subtype)
    family.accounts.build(
      name:        external_name,
      currency:    currency,
      balance:     0,
      accountable: accountable
    )
  end
end
