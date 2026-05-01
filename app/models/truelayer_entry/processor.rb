class TruelayerEntry::Processor
  def initialize(truelayer_transaction, truelayer_account:, import_adapter: nil)
    @truelayer_transaction = truelayer_transaction
    @truelayer_account     = truelayer_account
    @import_adapter        = import_adapter
  end

  def process
    unless account.present?
      Rails.logger.warn "TruelayerEntry::Processor — no linked account for truelayer_account #{truelayer_account.id}, skipping #{external_id}"
      return nil
    end

    import_adapter.import_transaction(
      external_id: external_id,
      amount:      amount,
      currency:    currency,
      date:        date,
      name:        name,
      merchant:    merchant,
      source:      "truelayer",
      notes:       notes,
      extra:       extra
    )
  rescue ArgumentError => e
    Rails.logger.error "TruelayerEntry::Processor — validation error for #{external_id_safe}: #{e.message}"
    raise
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    raise StandardError.new("Failed to import transaction: #{e.message}")
  end

  private

    attr_reader :truelayer_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= truelayer_account.current_account
    end

    def data
      @data ||= @truelayer_transaction.with_indifferent_access
    end

    def external_id
      id = data[:transaction_id].presence
      raise ArgumentError, "TrueLayer transaction missing required field 'transaction_id'" unless id
      "truelayer_#{id}"
    end

    # Safe version that won't raise — used in rescue logging before external_id is validated
    def external_id_safe
      id = data[:transaction_id].presence
      id ? "truelayer_#{id}" : "(no transaction_id)"
    end

    def amount
      raw_value = data[:amount]
      decimal_str = raw_value.is_a?(Float) ? format("%.10f", raw_value) : raw_value.to_s
      raw = BigDecimal(decimal_str).abs
      # Sure convention: positive = outflow (debit/expense), negative = inflow (credit/income)
      # TrueLayer: CREDIT = money into account (inflow = negative in Sure), DEBIT = money out (outflow = positive)
      data[:transaction_type] == "CREDIT" ? -raw : raw
    end

    def currency
      data[:currency].presence || truelayer_account.currency
    end

    def date
      parsed = Time.zone.parse(data[:timestamp].to_s)
      raise ArgumentError, "Missing or invalid timestamp: #{data[:timestamp].inspect}" unless parsed
      parsed.to_date
    end

    def name
      data[:merchant_name].presence || meta_counterparty_name || category_fallback_name || humanized_description || "TrueLayer Transaction"
    end

    # Creates a Merchant when TrueLayer provides a merchant_name (card purchases / identified payees)
    # or when the meta object contains a counterparty name.
    def merchant
      merchant_name = data[:merchant_name].to_s.strip.presence || meta_counterparty_name
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      import_adapter.find_or_create_merchant(
        provider_merchant_id: "truelayer_merchant_#{merchant_id}",
        name:                 merchant_name,
        source:               "truelayer"
      )
    end

    # Always preserve the raw bank description in notes so reference codes,
    # location info, and provider-specific text are never lost.
    def notes
      data[:description].presence
    end

    # Provides a humanized fallback name based on TrueLayer's transaction_category
    def category_fallback_name
      case data[:transaction_category].to_s.upcase
      when "TRANSFER"       then "Bank Transfer"
      when "ATM"            then "ATM Withdrawal"
      when "DIRECT_DEBIT"   then "Direct Debit"
      when "DIRECT_CREDIT"  then "Direct Credit"
      when "STANDING_ORDER" then "Standing Order"
      when "REPEAT_PAYMENT" then "Repeat Payment"
      when "INTEREST"       then "Interest"
      when "DIVIDEND"       then "Dividend"
      when "FEE"            then "Fee"
      when "CASH"           then "Cash"
      when "CHECK"          then "Cheque"
      else nil
      end
    end

    # Returns the description for use as a name, but rejects bare reference codes
    # (e.g. "R2391", "FP123456", "ACH-001") so they don't pollute the name field.
    def humanized_description
      desc = data[:description].to_s.strip
      return nil if desc.blank?
      return nil if desc.match?(/\A[A-Z]{1,4}[\-_]?\d{2,}\z/i)

      desc
    end

    # TrueLayer sometimes returns counterparty names inside the meta object
    # (e.g. meta['counter_party_preferred_name']). This is bank-dependent.
    def meta_counterparty_name
      meta = data[:meta].presence
      return nil unless meta.is_a?(Hash) || meta.is_a?(ActionController::Parameters)

      name = meta[:counter_party_preferred_name].presence ||
             meta[:counterparty_name].presence ||
             meta[:party_name].presence ||
             meta[:creditor_name].presence ||
             meta[:debtor_name].presence

      name&.to_s&.strip
    end

    def extra
      pending = data[:_pending] || data[:transaction_status] == "PENDING"
      result = { "truelayer" => { "pending" => pending } }

      norm_id = data[:normalised_provider_transaction_id].presence
      result["truelayer"]["normalised_provider_transaction_id"] = norm_id if norm_id

      category = data[:transaction_category].presence
      result["truelayer"]["transaction_category"] = category if category

      classification = data[:transaction_classification].presence
      result["truelayer"]["transaction_classification"] = classification if classification

      meta = data[:meta].presence
      result["truelayer"]["meta"] = meta if meta

      result
    end
end
