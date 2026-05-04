# Connection-framework adapter for Plaid (US + EU regions).
#
# Registered twice with Provider::ConnectionRegistry — once per region — so
# that "plaid_us" and "plaid_eu" are distinct provider_keys with separate
# bank-sync directory entries, but the adapter logic is shared. Region is
# stored on connection.metadata["region"] and consulted when the adapter
# needs to pick the right Provider::Plaid client.
#
# This is the new framework-side adapter; the legacy Provider::PlaidAdapter
# (per-account adapter registered with Provider::Factory) continues to serve
# existing PlaidItem rows during the cutover. The legacy adapter's
# .connection_configs returns [] so the bank-sync directory only shows the
# new entry.
class Provider::Plaid::Adapter
  extend Provider::ConnectionAdapter

  # Plaid type → Sure Accountable mapping.
  # https://plaid.com/docs/api/accounts/#account-type-schema
  TYPE_MAPPING = {
    "depository" => { accountable: Depository, subtype_mapping: {
      "checking" => "checking", "savings" => "savings", "hsa" => "hsa",
      "cd" => "cd", "money market" => "money_market"
    } },
    "credit" => { accountable: CreditCard, subtype_mapping: {
      "credit card" => "credit_card"
    } },
    "loan" => { accountable: Loan, subtype_mapping: {
      "mortgage" => "mortgage", "student" => "student", "auto" => "auto",
      "business" => "business", "home equity" => "home_equity",
      "line of credit" => "line_of_credit"
    } },
    "investment" => { accountable: Investment, subtype_mapping: {
      "brokerage" => "brokerage", "pension" => "pension", "retirement" => "retirement",
      "401k" => "401k", "roth 401k" => "roth_401k", "403b" => "403b", "457b" => "457b",
      "529" => "529_plan", "hsa" => "hsa", "mutual fund" => "mutual_fund",
      "roth" => "roth_ira", "ira" => "ira", "sep ira" => "sep_ira",
      "simple ira" => "simple_ira", "trust" => "trust", "ugma" => "ugma", "utma" => "utma"
    } }
  }.freeze

  def self.display_name = "Plaid"
  def self.description  = "Connect US and EU banks via Plaid"
  def self.brand_color  = "#000000"
  def self.beta?        = false

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.syncer_class = Provider::Plaid::Syncer
  def self.auth_class   = Provider::Auth::EmbeddedLink

  # Returns both regional configs (US and EU) on every call — the adapter is
  # registered twice (plaid_us + plaid_eu) so ConnectionRegistry calls this
  # once per key. ConnectionRegistry.all_connection_configs dedupes by
  # config[:key], so the bank-sync directory ends up with each region listed
  # once regardless of how many registrations point here.
  def self.connection_configs(family:)
    configs = []
    if family.respond_to?(:can_connect_plaid_us?) && family.can_connect_plaid_us?
      configs << {
        key:  "plaid_us",
        name: "Plaid",
        description: "Connect to your US bank via Plaid",
        new_account_path: ->(_accountable_type, _return_to) {
          Rails.application.routes.url_helpers.new_plaid_link_callbacks_path(region: "us")
        },
        existing_account_path: nil
      }
    end
    if family.respond_to?(:can_connect_plaid_eu?) && family.can_connect_plaid_eu?
      configs << {
        key:  "plaid_eu",
        name: "Plaid (EU)",
        description: "Connect to your EU bank via Plaid",
        new_account_path: ->(_accountable_type, _return_to) {
          Rails.application.routes.url_helpers.new_plaid_link_callbacks_path(region: "eu")
        },
        existing_account_path: nil
      }
    end
    configs
  end

  def self.build_sure_account(provider_account, family:)
    type    = provider_account.external_type.to_s
    subtype = provider_account.external_subtype.to_s
    mapping = TYPE_MAPPING[type] ||
      raise(Provider::Account::UnsupportedAccountableType,
            "Provider::Plaid::Adapter does not handle external_type=#{type.inspect}")

    accountable_subtype = mapping[:subtype_mapping][subtype] || "other"
    accountable = mapping[:accountable].new(subtype: accountable_subtype)

    family.accounts.build(
      name:        provider_account.external_name,
      currency:    provider_account.currency,
      balance:     0,
      accountable: accountable
    )
  end
end

Provider::ConnectionRegistry.register("plaid_us", Provider::Plaid::Adapter)
Provider::ConnectionRegistry.register("plaid_eu", Provider::Plaid::Adapter)
