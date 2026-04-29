class TruelayerItem::Importer
  attr_reader :truelayer_item

  def initialize(truelayer_item)
    @truelayer_item = truelayer_item
  end

  def import
    provider = truelayer_item.truelayer_provider
    unless provider
      Rails.logger.error "TruelayerItem::Importer #{truelayer_item.id} — provider not configured"
      return { success: false, error: "TrueLayer provider not configured" }
    end

    psu_ip = truelayer_item.last_psu_ip

    upsert_accounts(provider, psu_ip: psu_ip)
    update_pending_account_setup!

    unless truelayer_item.pending_account_setup?
      import_transactions(provider, psu_ip: psu_ip)
      update_balances(provider, psu_ip: psu_ip)
    end

    { success: true }
  rescue Provider::Truelayer::TruelayerError => e
    if e.error_type == :unauthorized
      truelayer_item.update!(status: :requires_update)
    end
    Rails.logger.error "TruelayerItem::Importer #{truelayer_item.id} — API error: #{e.message}"
    { success: false, error: e.message }
  rescue => e
    Rails.logger.error "TruelayerItem::Importer #{truelayer_item.id} — unexpected error: #{e.message}"
    { success: false, error: e.message }
  end

  private

    def upsert_accounts(provider, psu_ip:)
      begin
        accounts_data = provider.get_accounts(psu_ip: psu_ip)
        accounts_data.each { |d| upsert_account(d, kind: "account") }
      rescue Provider::Truelayer::TruelayerError => e
        raise unless e.error_type == :not_implemented
      end

      begin
        cards_data = provider.get_cards(psu_ip: psu_ip)
        cards_data.each { |d| upsert_account(d, kind: "card") }
      rescue Provider::Truelayer::TruelayerError => e
        raise unless e.error_type == :not_implemented
      end
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

    def update_balances(provider, psu_ip:)
      truelayer_item.truelayer_accounts.includes(account_provider: :account).each do |ta|
        account = ta.current_account
        next unless account

        begin
          balance_data = provider.get_balance(account_id: ta.account_id, kind: ta.account_kind, psu_ip: psu_ip)
          next unless balance_data

          current = balance_data[:current]
          next unless current.present?

          if ta.card?
            # TrueLayer returns current as negative for cards (debt convention); abs gives the amount owed
            account.credit_card&.update!(available_credit: balance_data[:available].to_d) if balance_data[:available].present?
            result = account.set_current_balance(current.to_d.abs)
          else
            result = account.set_current_balance(current.to_d)
          end

          Rails.logger.error "TruelayerItem::Importer — failed to set balance for account #{ta.id}: #{result.error}" unless result.success?
        rescue Provider::Truelayer::TruelayerError => e
          raise if e.error_type == :unauthorized
          Rails.logger.error "TruelayerItem::Importer — failed to fetch balance for account #{ta.id}: #{e.message}"
        end
      end
    end

    def import_transactions(provider, psu_ip:)
      from = truelayer_item.sync_start_date&.to_date || 90.days.ago.to_date
      to   = Date.current

      truelayer_item.truelayer_accounts.includes(account_provider: :account).each do |ta|
        next unless ta.current_account.present?

        begin
          settled = provider.get_transactions(
            account_id: ta.account_id,
            kind:       ta.account_kind,
            from:       from,
            to:         to,
            psu_ip:     psu_ip
          )
          settled.each { |tx| TruelayerEntry::Processor.new(tx, truelayer_account: ta).process }
        rescue Provider::Truelayer::TruelayerError => e
          raise if e.error_type == :unauthorized
          Rails.logger.error "TruelayerItem::Importer — failed to import settled transactions for account #{ta.id}: #{e.message}"
        end

        begin
          pending = provider.get_pending_transactions(
            account_id: ta.account_id,
            kind:       ta.account_kind,
            psu_ip:     psu_ip
          )
          pending.each do |tx|
            TruelayerEntry::Processor.new(
              tx.merge(_pending: true),
              truelayer_account: ta
            ).process
          end
        rescue Provider::Truelayer::TruelayerError => e
          raise if e.error_type == :unauthorized
          next if e.error_type == :not_implemented
          Rails.logger.error "TruelayerItem::Importer — failed to import pending transactions for account #{ta.id}: #{e.message}"
        end
      end
    end
end
