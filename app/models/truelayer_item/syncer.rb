class TruelayerItem::Syncer
  include SyncStats::Collector

  attr_reader :truelayer_item

  def initialize(truelayer_item)
    @truelayer_item = truelayer_item
  end

  def perform_sync(sync)
    unless truelayer_item.token_valid?
      if truelayer_item.token_expired?
        sync.update!(status_text: "Refreshing TrueLayer token...") if sync.respond_to?(:status_text)
        truelayer_item.refresh_tokens!
        unless truelayer_item.token_valid?
          truelayer_item.update!(status: :requires_update)
          raise StandardError.new("TrueLayer token not valid after refresh — re-authorization required")
        end
      else
        truelayer_item.update!(status: :requires_update)
        raise StandardError.new("TrueLayer token not valid — re-authorization required")
      end
    end

    if sync.respond_to?(:balances_only?) && sync.balances_only?
      sync.update!(status_text: "Discovering accounts (balances only)...") if sync.respond_to?(:status_text)
      import_result = truelayer_item.import_latest_truelayer_data(balances_only: true)
    else
      sync.update!(status_text: "Importing from TrueLayer...") if sync.respond_to?(:status_text)
      import_result = truelayer_item.import_latest_truelayer_data
    end

    unless import_result[:success]
      raise StandardError.new(import_result[:error].presence || "Import failed")
    end

    # Auto-clear requires_update on successful sync
    if truelayer_item.status == "requires_update"
      truelayer_item.update!(status: :good)
    end

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: truelayer_item.truelayer_accounts.includes(:account_provider, :account))

    unlinked = truelayer_item.truelayer_accounts.left_joins(:account_provider).where(account_providers: { id: nil }, setup_skipped: false)
    truelayer_item.update!(pending_account_setup: unlinked.any?)

    linked_account_ids = truelayer_item.truelayer_accounts
      .joins(:account_provider)
      .joins(:account)
      .merge(Account.visible)
      .pluck("accounts.id")

    if linked_account_ids.any?
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      collect_transaction_stats(sync, account_ids: linked_account_ids, source: "truelayer")
      truelayer_item.schedule_account_syncs(
        parent_sync:       sync,
        window_start_date: sync.window_start_date,
        window_end_date:   sync.window_end_date
      )
    end

    collect_health_stats(sync, errors: nil)
  rescue => e
    category = classify_error(e)
    collect_health_stats(sync, errors: [ { message: e.message, category: category } ])
    raise
  end

  def perform_post_sync
    # no-op
  end

  private

    def classify_error(error)
      return "auth" if error.is_a?(Provider::Truelayer::TruelayerError) && [ :unauthorized, :sca_exceeded, :forbidden ].include?(error.error_type)
      return "network" if error.is_a?(Provider::Truelayer::TruelayerError) && [ :request_failed, :rate_limited ].include?(error.error_type)
      return "api" if error.is_a?(Provider::Truelayer::TruelayerError) && [ :bad_request, :not_found, :not_implemented, :fetch_failed, :parse_error ].include?(error.error_type)
      "other"
    end
end
