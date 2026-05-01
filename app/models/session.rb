class Session < ApplicationRecord
  include Encryptable

  # Encrypt user_agent if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :user_agent
  end

  belongs_to :user
  belongs_to :active_impersonator_session,
    -> { where(status: :in_progress) },
    class_name: "ImpersonationSession",
    optional: true

  before_create :capture_session_info

  def get_preferred_tab(tab_key)
    data.dig("tab_preferences", tab_key)
  end

  def set_preferred_tab(tab_key, tab_value)
    data["tab_preferences"] ||= {}
    data["tab_preferences"][tab_key] = tab_value
    save!
  end

  def id_token_hint
    data["id_token_hint"]
  end

  def id_token_hint=(value)
    self.data = data.merge("id_token_hint" => value)
  end

  def oidc_provider
    data["oidc_provider"]
  end

  def oidc_provider=(value)
    self.data = data.merge("oidc_provider" => value)
  end

  private

    def capture_session_info
      self.user_agent = Current.user_agent
      raw_ip = Current.ip_address
      self.ip_address = raw_ip
      self.ip_address_digest = Digest::SHA256.hexdigest(raw_ip.to_s) if raw_ip.present?
    end
end
