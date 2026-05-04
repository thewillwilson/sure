# Connection-framework syncer for Plaid.
#
# Phase 2 (current) implements only #discover_accounts_only — the bare minimum
# the Plaid Link callback flow needs after exchanging public_token, so the
# user lands on the setup page with provider_accounts already populated.
#
# Phase 3 fills in #perform_sync (transactions, holdings, liabilities, balance
# anchoring, etc.) and ports the existing PlaidAccount sub-processors into the
# Provider::Plaid::* namespace.
class Provider::Plaid::Syncer
  include SyncStats::Collector

  def initialize(connection)
    @connection = connection
  end

  def discover_accounts_only
    response = client.get_item_accounts(access_token)
    response.accounts.each do |raw|
      @connection.provider_accounts
                 .find_or_initialize_by(external_id: raw.account_id)
                 .update!(
                   external_name:    raw.name,
                   external_type:    raw.type,
                   external_subtype: raw.subtype,
                   currency:         raw.balances&.iso_currency_code || raw.balances&.unofficial_currency_code,
                   raw_payload:      raw.to_hash
                 )
    end
  end

  # Phase 3 fills this in. Until then, calling perform_sync on a Plaid
  # connection is a programming error — connections shouldn't reach the
  # sync path until the syncer is complete.
  def perform_sync(sync)
    raise NotImplementedError, "Provider::Plaid::Syncer#perform_sync is built in Phase 3"
  end

  def perform_post_sync; end

  private

    def client
      Provider::Registry.plaid_provider_for_region(region)
    end

    def access_token
      @connection.credentials["access_token"]
    end

    def region
      (@connection.metadata["region"] || "us").to_sym
    end
end
