class TruelayerItem::Importer
  CHUNK_SIZE_DAYS = 60
  MAX_CHUNKS      = 6

  STALE_PENDING_DAYS = 8
  GAP_THRESHOLD_DAYS = 14

  attr_reader :truelayer_item

  def initialize(truelayer_item)
    @truelayer_item = truelayer_item
  end

  def import(balances_only: false)
    provider = truelayer_item.truelayer_provider
    unless provider
      Rails.logger.error "TruelayerItem::Importer #{truelayer_item.id} — provider not configured"
      return { success: false, error: "TrueLayer provider not configured" }
    end

    update_consent_expiry(provider)
    upsert_accounts(provider)
    prune_orphaned_accounts(provider)
    update_pending_account_setup!

    unless truelayer_item.pending_account_setup?
      if balances_only
        update_balances(provider)
      else
        import_transactions(provider)
        update_balances(provider)
        cleanup_stale_pending_transactions
        detect_transaction_gaps
      end
    end

    { success: true }
  rescue Provider::Truelayer::TruelayerError => e
    if [ :unauthorized, :sca_exceeded ].include?(e.error_type)
      truelayer_item.update!(status: :requires_update)
    end
    Rails.logger.error "TruelayerItem::Importer #{truelayer_item.id} — API error: #{e.message}"
    { success: false, error: e.message }
  rescue => e
    Rails.logger.error "TruelayerItem::Importer #{truelayer_item.id} — unexpected error: #{e.message}"
    { success: false, error: e.message }
  end

  private

    def update_consent_expiry(provider)
      return if truelayer_item.consent_expires_at.present?

      me = provider.get_me
      expiry = me&.dig(:consent_expiry_time).presence
      truelayer_item.update!(consent_expires_at: Time.zone.parse(expiry)) if expiry
    rescue => e
      Rails.logger.warn "TruelayerItem::Importer — could not fetch consent expiry: #{e.message}"
    end

    def upsert_accounts(provider)
      begin
        accounts_data = provider.get_accounts
        accounts_data.each { |d| upsert_account(d, kind: "account") }
      rescue Provider::Truelayer::TruelayerError => e
        raise unless e.error_type == :not_implemented
      end

      begin
        cards_data = provider.get_cards
        cards_data.each { |d| upsert_account(d, kind: "card") }
      rescue Provider::Truelayer::TruelayerError => e
        raise unless e.error_type == :not_implemented
      end
    end

    def prune_orphaned_accounts(provider)
      active_ids = []

      begin
        active_ids += provider.get_accounts.map { |d| d[:account_id] }
      rescue Provider::Truelayer::TruelayerError => e
        raise unless e.error_type == :not_implemented
      end

      begin
        active_ids += provider.get_cards.map { |d| d[:account_id] }
      rescue Provider::Truelayer::TruelayerError => e
        raise unless e.error_type == :not_implemented
      end

      return if active_ids.empty?

      orphaned = truelayer_item.truelayer_accounts
        .where.not(account_id: active_ids.compact)

      orphaned.find_each do |ta|
        Rails.logger.info "TruelayerItem::Importer — pruning orphaned account #{ta.account_id} (#{ta.name})"
        ta.destroy!
      end
    rescue => e
      Rails.logger.warn "TruelayerItem::Importer — failed to prune orphaned accounts: #{e.message}"
    end

    def upsert_account(account_data, kind:)
      data       = account_data.with_indifferent_access
      account_id = data[:account_id]
      return unless account_id.present?

      ta = truelayer_item.truelayer_accounts.find_or_initialize_by(account_id: account_id)
      ta.upsert_truelayer_snapshot!(account_data, account_kind: kind)
    end

    def update_pending_account_setup!
      has_unlinked = truelayer_item.truelayer_accounts
        .left_joins(:account_provider)
        .where(account_providers: { id: nil }, setup_skipped: false)
        .exists?

      truelayer_item.update!(pending_account_setup: has_unlinked)
    end

    def update_balances(provider)
      truelayer_item.truelayer_accounts.includes(account_provider: :account).each do |ta|
        account = ta.current_account
        next unless account

        begin
          balance_data = provider.get_balance(account_id: ta.account_id, kind: ta.account_kind)
          next unless balance_data

          current = balance_data[:current]
          next unless current.present?

          if ta.card?
            if balance_data[:available].present? && balance_data[:available] != balance_data[:current]
              account.credit_card&.update!(available_credit: balance_data[:available].to_d.abs)
            end
            result = account.set_current_balance(current.to_d.abs)
          else
            result = account.set_current_balance(current.to_d)
          end

          Rails.logger.error "TruelayerItem::Importer — failed to set balance for account #{ta.id}: #{result.error}" unless result.success?
        rescue Provider::Truelayer::TruelayerError => e
          raise if [ :unauthorized, :sca_exceeded ].include?(e.error_type)
          Rails.logger.error "TruelayerItem::Importer — failed to fetch balance for account #{ta.id}: #{e.message}"
        end
      end
    end

    def import_transactions(provider)
      from = if truelayer_item.sync_start_date.present?
               truelayer_item.sync_start_date.to_date
             elsif truelayer_item.last_synced_at.present?
               (truelayer_item.last_synced_at.to_date - 3.days)
             else
               90.days.ago.to_date
             end
      to   = Date.current

      truelayer_item.truelayer_accounts.includes(account_provider: :account).each do |ta|
        next unless ta.current_account.present?

        begin
          if truelayer_item.last_synced_at.nil?
            import_transactions_chunked(provider, ta, from, to)
          else
            settled = provider.get_transactions(
              account_id: ta.account_id,
              kind:       ta.account_kind,
              from:       from,
              to:         to
            )
            settled.each { |tx| TruelayerEntry::Processor.new(tx, truelayer_account: ta).process }
          end
        rescue Provider::Truelayer::TruelayerError => e
          raise if [ :unauthorized, :sca_exceeded ].include?(e.error_type)
          Rails.logger.error "TruelayerItem::Importer — failed to import settled transactions for account #{ta.id}: #{e.message}"
        end

        begin
          pending = provider.get_pending_transactions(
            account_id: ta.account_id,
            kind:       ta.account_kind
          )
          pending.each do |tx|
            TruelayerEntry::Processor.new(
              tx.merge(_pending: true),
              truelayer_account: ta
            ).process
          end
        rescue Provider::Truelayer::TruelayerError => e
          raise if [ :unauthorized, :sca_exceeded ].include?(e.error_type)
          next if e.error_type == :not_implemented
          Rails.logger.error "TruelayerItem::Importer — failed to import pending transactions for account #{ta.id}: #{e.message}"
        end
      end
    end

    def import_transactions_chunked(provider, ta, from, to)
      all_transactions = []
      chunk_end = to

      MAX_CHUNKS.times do
        chunk_start = [chunk_end - CHUNK_SIZE_DAYS.days, from].max
        chunk = provider.get_transactions(
          account_id: ta.account_id,
          kind:       ta.account_kind,
          from:       chunk_start,
          to:         chunk_end
        )
        all_transactions.concat(chunk)
        break if chunk.empty?
        chunk_end = chunk_start - 1.day
        break if chunk_end < from
      end

      all_transactions.each { |tx| TruelayerEntry::Processor.new(tx, truelayer_account: ta).process }
    end

    def cleanup_stale_pending_transactions
      stale_cutoff = STALE_PENDING_DAYS.days.ago

      truelayer_item.truelayer_accounts.includes(account_provider: :account).each do |ta|
        account = ta.current_account
        next unless account

        stale_pending = account.entries
          .where(source: "truelayer", entryable_type: "Transaction")
          .joins(:transaction)
          .where(transactions: { pending: true })
          .where("entries.created_at < ?", stale_cutoff)

        stale_pending.find_each do |entry|
          Rails.logger.info "TruelayerItem::Importer — removing stale pending entry #{entry.id}"
          entry.destroy!
        end
      end
    rescue => e
      Rails.logger.warn "TruelayerItem::Importer — failed to cleanup stale pending: #{e.message}"
    end

    def detect_transaction_gaps
      truelayer_item.truelayer_accounts.includes(account_provider: :account).each do |ta|
        account = ta.current_account
        next unless account

        dates = account.entries
          .where(source: "truelayer", entryable_type: "Transaction")
          .joins(:transaction)
          .where.not(transactions: { raw_date: nil })
          .pluck("transactions.raw_date")
          .map { |d| d.is_a?(Date) ? d : Date.parse(d.to_s) }
          .sort

        next if dates.size < 2

        dates.each_cons(2) do |a, b|
          gap = (b - a).to_i
          if gap > GAP_THRESHOLD_DAYS
            Rails.logger.warn "TruelayerItem::Importer — transaction gap detected for account #{ta.id}: #{gap} days between #{a} and #{b}"
          end
        end
      end
    rescue => e
      Rails.logger.warn "TruelayerItem::Importer — failed to detect transaction gaps: #{e.message}"
    end
end
