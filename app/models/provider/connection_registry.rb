# Registry of adapter classes that back Provider::Connection records.
# Auth-type agnostic: OAuth2 adapters (TrueLayer) and non-OAuth adapters
# (e.g. Plaid Link) register here by their provider_key string.
module Provider::ConnectionRegistry
  Error = Class.new(StandardError)

  class << self
    def register(key, adapter_class)
      registry[key.to_s] = adapter_class
    end

    def registered?(key)
      Provider::Factory.ensure_adapters_loaded
      registry.key?(key.to_s)
    end

    def keys
      Provider::Factory.ensure_adapters_loaded
      registry.keys
    end

    def adapter_for(key)
      Provider::Factory.ensure_adapters_loaded
      registry[key.to_s] or raise NotImplementedError, "No connection adapter registered for: #{key}"
    end

    def syncer_class_for(key)
      adapter = adapter_for(key)
      unless adapter.respond_to?(:syncer_class)
        raise NotImplementedError, "Adapter for '#{key}' (#{adapter}) does not define syncer_class"
      end
      adapter.syncer_class
    end

    def config_for(key)
      adapter_for(key).new(nil)
    end

    private

      def registry
        @registry ||= {}
      end
  end
end
