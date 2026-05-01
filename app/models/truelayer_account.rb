class TruelayerAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
  end

  belongs_to :truelayer_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  validates :name,       presence: true
  validates :account_id, presence: true,
                         uniqueness: { scope: :truelayer_item_id }

  ACCOUNT_TYPE_MAP = {
    "TRANSACTION"          => { type: "Depository", subtype: "checking" },
    "SAVINGS"              => { type: "Depository", subtype: "savings"  },
    "BUSINESS_TRANSACTION" => { type: "Depository", subtype: "checking" },
    "BUSINESS_SAVINGS"     => { type: "Depository", subtype: "savings"  }
  }.freeze

  def suggested_account_type
    return "CreditCard" if card?
    ACCOUNT_TYPE_MAP[account_type&.upcase]&.dig(:type) || "Depository"
  end

  def suggested_subtype
    return "credit_card" if card?
    ACCOUNT_TYPE_MAP[account_type&.upcase]&.dig(:subtype)
  end

  def card?
    account_kind == "card"
  end

  def display_type
    subtype = suggested_subtype
    return suggested_account_type.constantize.short_subtype_label_for(subtype) if subtype.present?
    account_type&.humanize || "Account"
  end

  def masked_account_number
    number = parsed_raw_payload&.dig("account_number", "number")
    return "\u2022\u2022\u2022\u2022#{number.last(4)}" if number.present?
    sort_code = parsed_raw_payload&.dig("account_number", "sort_code")
    "Sort code: #{sort_code}" if sort_code.present?
  end

  def provider_display_name
    parsed_raw_payload&.dig("provider", "display_name")
  end

  def provider_logo_uri
    parsed_raw_payload&.dig("provider", "logo_uri")
  end

  def current_account
    account
  end

  def create_linked_account!(family:)
    accountable_attrs = suggested_subtype.present? ? { subtype: suggested_subtype } : {}
    account = Account.create_and_sync(
      {
        family:                 family,
        name:                   name,
        balance:                0,
        currency:               currency,
        institution_name:       provider_display_name,
        accountable_type:       suggested_account_type,
        accountable_attributes: accountable_attrs
      },
      skip_initial_sync: true
    )
    AccountProvider.create!(account: account, provider: self)
    account
  end

  def upsert_truelayer_snapshot!(account_data, account_kind: nil)
    data = account_data.with_indifferent_access
    attrs = {
      name:         data[:display_name].presence || "TrueLayer Account",
      currency:     parse_currency(data[:currency]),
      account_type: data[:account_type],
      raw_payload:  account_data
    }
    attrs[:account_kind] = account_kind if account_kind.present?
    update!(attrs)
  end

  private

    def parsed_raw_payload
      return nil if raw_payload.nil?
      return raw_payload if raw_payload.is_a?(Hash)

      str = raw_payload.to_s.strip
      return nil if str.blank?

      begin
        JSON.parse(str)
      rescue JSON::ParserError
        YAML.safe_load(str) || {}
      end
    end
end
