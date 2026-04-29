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
      raw = BigDecimal(data[:amount].to_s).abs
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
      data[:merchant_name].presence || data[:description].presence || "TrueLayer Transaction"
    end

    def notes
      return nil if data[:merchant_name].present?
      data[:description].presence
    end

    def extra
      truelayer_extra = {}
      truelayer_extra["pending"] = true if data[:_pending] || data[:transaction_status] == "PENDING"
      return nil if truelayer_extra.empty?
      { "truelayer" => truelayer_extra }
    end
end
