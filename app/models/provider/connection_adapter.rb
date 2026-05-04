# Class-method contract for adapters registered with Provider::ConnectionRegistry.
#
# Adapters extend this module to inherit defaults for optional methods and
# pick up NotImplementedError stubs that document the required surface:
#
#   class Provider::TruelayerAdapter
#     extend Provider::ConnectionAdapter
#
#     def self.display_name = "TrueLayer"
#     def self.supported_account_types = %w[Depository CreditCard]
#     def self.syncer_class = Provider::TruelayerSyncer
#     def self.connection_configs(family:) = [...]
#     def self.build_sure_account(provider_account, family:) = ...
#   end
#
# The module exists so the contract is grep-able (`extend Provider::ConnectionAdapter`
# at the top of every adapter is the entry point a reader can follow) and so adapter
# authors get a clear NotImplementedError pointing at the method they forgot, rather
# than the symptom downstream.
module Provider::ConnectionAdapter
  # ---- Required ----------------------------------------------------------

  # Human-readable provider name (e.g. "TrueLayer").
  def display_name
    raise NotImplementedError, "#{self} must define .display_name"
  end

  # Sure Accountable subclass names this provider produces (e.g. %w[Depository CreditCard]).
  # Used by the Add-Account flow to filter providers per accountable type.
  def supported_account_types
    raise NotImplementedError, "#{self} must define .supported_account_types"
  end

  # Syncer class instantiated as `syncer_class.new(connection)` by Provider::Connection#syncer.
  # The syncer must implement #perform_sync(sync) and #discover_accounts_only.
  def syncer_class
    raise NotImplementedError, "#{self} must define .syncer_class"
  end

  # Array of connection-config hashes consumed by the bank-sync directory.
  # Each hash describes one entry point (key, name, new_account_path lambda, etc.).
  def connection_configs(family:)
    raise NotImplementedError, "#{self} must define .connection_configs(family:)"
  end

  # Build (do NOT save) a Sure Account record from a Provider::Account.
  # Adapters own their external_type → Accountable mapping and any per-type
  # customisation (e.g. an investments adapter would build Holdings here).
  # Raise Provider::Account::UnsupportedAccountableType for types this adapter
  # doesn't handle, rather than silently mis-categorising.
  def build_sure_account(provider_account, family:)
    raise NotImplementedError, "#{self} must define .build_sure_account(provider_account, family:)"
  end

  # Auth backend used by Provider::Connection#auth to handle the credential
  # lifecycle (token exchange, refresh, reauth). OAuth2 adapters return
  # Provider::Auth::OAuth2; embedded-link adapters (e.g. Plaid Link) return
  # Provider::Auth::EmbeddedLink. The class must accept (connection) on init.
  def auth_class
    raise NotImplementedError, "#{self} must define .auth_class"
  end

  # ---- Optional (with defaults) ------------------------------------------

  def beta? = false
  def brand_color = "#6B7280"
  def description = nil

  # Provider-specific reauth URL (e.g. TrueLayer /v1/reauthuri). Return nil
  # to fall back to the standard authorize URL with the persisted redirect_uri.
  def reauth_url(connection, redirect_uri:, state:)
    nil
  end

  # Verifies the upstream webhook signature and raises if invalid. Adapters
  # that don't accept webhooks can leave this raising. Webhooks::ProviderController
  # calls this before dispatching to the handler.
  def verify_webhook!(headers:, raw_body:)
    raise NotImplementedError, "#{self} does not accept webhooks"
  end

  # Class implementing #process and accepting (connection:, raw_body:, headers:).
  # Webhooks::ProviderController instantiates and calls #process after signature
  # verification succeeds.
  def webhook_handler_class
    raise NotImplementedError, "#{self} does not accept webhooks"
  end
end
