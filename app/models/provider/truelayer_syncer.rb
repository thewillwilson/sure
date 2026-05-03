class Provider::TruelayerSyncer
  include SyncStats::Collector

  def initialize(connection)
    @connection = connection
    @auth       = Provider::Auth::OAuth2.new(connection)
    @adapter    = Provider::TruelayerAdapter.new(connection)
  end

  def perform_sync(sync)
    token = @auth.fresh_access_token # pipelock:ignore
    discover_accounts(token)
    collect_setup_stats(sync, provider_accounts: @connection.provider_accounts)
    sync_linked_accounts(token, sync)
    @connection.update!(status: :good, last_synced_at: Time.current, sync_error: nil)
  rescue Provider::Auth::ReauthRequiredError
    @connection.update!(status: :requires_update, sync_error: "reauth_required")
  rescue Provider::Auth::TransientError => e
    # Transient (network/5xx). Don't surface in UI; let Sidekiq retry.
    Rails.logger.warn("[#{self.class.name}] transient sync failure for connection=#{@connection.id}: #{e.message}")
    raise
  rescue => e
    @connection.update!(sync_error: e.message)
    raise
  ensure
    collect_health_stats(sync)
  end

  def discover_accounts_only
    token = @auth.fresh_access_token # pipelock:ignore
    discover_accounts(token)
  end

  def perform_post_sync; end

  private

    def discover_accounts(token)
      @adapter.fetch_accounts(token).each do |raw|
        @connection.provider_accounts
                   .find_or_initialize_by(external_id: raw[:external_id])
                   .update!(
                     external_name:    raw[:name],
                     external_type:    raw[:type],
                     external_subtype: raw[:subtype],
                     currency:         raw[:currency],
                     raw_payload:      raw[:raw_payload]
                   )
      end
    end

    def sync_linked_accounts(token, sync)
      window_start = sync.window_start_date&.beginning_of_day
      to           = sync.window_end_date&.end_of_day || Time.current

      linked_accounts = @connection.provider_accounts.where.not(account_id: nil).includes(:account)
      linked_accounts.each do |pa|
        # Per-account window: a freshly-linked account gets its own 90-day backfill,
        # not whatever window a previously-synced sibling has already covered.
        from = window_start || pa.last_synced_at || 90.days.ago
        import_adapter = Account::ProviderImportAdapter.new(pa.account)
        @adapter.fetch_transactions(token, pa, from: from, to: to).each do |t|
          merchant = build_merchant(t, import_adapter)

          extra = { "truelayer" => { "pending" => t[:pending], "raw" => t[:raw] } }
          extra["truelayer"]["normalised_provider_transaction_id"] = t[:normalised_provider_transaction_id] if t[:normalised_provider_transaction_id].present?
          extra["truelayer"]["transaction_category"]               = t[:transaction_category]               if t[:transaction_category].present?
          extra["truelayer"]["transaction_classification"]         = t[:transaction_classification]         if t[:transaction_classification].present?
          extra["truelayer"]["meta"]                               = t[:meta]                               if t[:meta].present?

          import_adapter.import_transaction(
            external_id: t[:external_id],
            amount:      t[:amount],
            currency:    t[:currency],
            date:        t[:date],
            name:        t[:name],
            merchant:    merchant,
            notes:       t[:notes],
            source:      "truelayer",
            extra:       extra
          )
        end

        balance_anchored = anchor_balance(token, pa)

        pa.update!(last_synced_at: Time.current)
        collect_transaction_stats(sync, account_ids: [ pa.account_id ], source: "truelayer")
        pa.account.sync_later unless balance_anchored
      end
    end

    def build_merchant(t, import_adapter)
      name = t[:merchant_name].to_s.strip.presence
      return nil unless name

      merchant_id = Digest::MD5.hexdigest(name.downcase)
      import_adapter.find_or_create_merchant(
        provider_merchant_id: "truelayer_merchant_#{merchant_id}",
        name:                 name,
        source:               "truelayer"
      )
    end

    def anchor_balance(token, pa)
      raw = @adapter.fetch_balance(token, pa)
      return false unless raw && raw["current"].present?

      balance = BigDecimal(raw["current"].to_s)
      pa.account.set_current_balance(balance)

      if pa.account.accountable_type == "CreditCard"
        avail_raw = raw["available"] || raw["credit_limit"]
        if avail_raw.present?
          avail = BigDecimal(avail_raw.to_s)
          pa.account.credit_card.update!(available_credit: avail) if avail > 0
        end
      end

      true
    rescue => e
      Rails.logger.warn "TruelayerSyncer: balance fetch failed for provider_account=#{pa.id}: #{e.message}"
      false
    end
end
