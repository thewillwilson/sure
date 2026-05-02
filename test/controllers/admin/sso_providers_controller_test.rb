require "test_helper"

class Admin::SsoProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:sure_support_staff)
  end

  test "destroy does not auto-enable local login when other enabled providers remain" do
    original_local_login = Setting.local_login_enabled

    provider1 = SsoProvider.create!(
      strategy: "openid_connect",
      name: "provider_one",
      label: "Provider One",
      enabled: true,
      issuer: "https://one.example.com",
      client_id: "client1",
      client_secret: "secret1"
    )
    provider2 = SsoProvider.create!(
      strategy: "openid_connect",
      name: "provider_two",
      label: "Provider Two",
      enabled: true,
      issuer: "https://two.example.com",
      client_id: "client2",
      client_secret: "secret2"
    )

    Setting.local_login_enabled = false

    delete admin_sso_provider_url(provider1)

    assert_redirected_to admin_sso_providers_path
    assert_not Setting.local_login_enabled, "local login should remain disabled"
    assert_equal I18n.t("admin.sso_providers.destroy.success"), flash[:notice]
  ensure
    Setting.local_login_enabled = original_local_login
    provider2.destroy rescue nil
  end

  test "destroy does not auto-enable local login when last enabled provider deleted but local login already enabled" do
    provider = SsoProvider.create!(
      strategy: "openid_connect",
      name: "only_provider",
      label: "Only Provider",
      enabled: true,
      issuer: "https://example.com",
      client_id: "client",
      client_secret: "secret"
    )

    Setting.local_login_enabled = true

    delete admin_sso_provider_url(provider)

    assert_redirected_to admin_sso_providers_path
    assert_equal I18n.t("admin.sso_providers.destroy.success"), flash[:notice]
  end

  test "destroy prevents lockout when it would be the last enabled provider and local login is disabled" do
    original_local_login = Setting.local_login_enabled

    provider = SsoProvider.create!(
      strategy: "openid_connect",
      name: "only_provider",
      label: "Only Provider",
      enabled: true,
      issuer: "https://example.com",
      client_id: "client",
      client_secret: "secret"
    )

    Setting.local_login_enabled = false
    AuthConfig.stubs(:local_login_enabled?).returns(false)

    assert_no_difference "SsoProvider.count" do
      delete admin_sso_provider_url(provider)
    end

    assert_redirected_to admin_sso_providers_path
    assert_equal I18n.t("admin.sso_providers.index.lockout_prevented"), flash[:alert]
  ensure
    Setting.local_login_enabled = original_local_login
    provider.destroy rescue nil
  end

  test "toggle prevents lockout when disabling the last enabled provider while local login is disabled" do
    original_local_login = Setting.local_login_enabled

    provider = SsoProvider.create!(
      strategy: "openid_connect",
      name: "only_provider_toggle",
      label: "Only Provider Toggle",
      enabled: true,
      issuer: "https://example.com",
      client_id: "client",
      client_secret: "secret"
    )

    Setting.local_login_enabled = false
    AuthConfig.stubs(:local_login_enabled?).returns(false)

    patch toggle_admin_sso_provider_url(provider)

    assert_redirected_to admin_sso_providers_path
    assert_equal I18n.t("admin.sso_providers.index.lockout_prevented"), flash[:alert]
    assert provider.reload.enabled?, "provider should still be enabled"
  ensure
    Setting.local_login_enabled = original_local_login
    provider.destroy rescue nil
  end

  test "toggle allows disabling a provider when another enabled provider exists and local login is disabled" do
    original_local_login = Setting.local_login_enabled

    provider1 = SsoProvider.create!(
      strategy: "openid_connect",
      name: "provider_toggle_one",
      label: "Provider Toggle One",
      enabled: true,
      issuer: "https://one.example.com",
      client_id: "client1",
      client_secret: "secret1"
    )
    provider2 = SsoProvider.create!(
      strategy: "openid_connect",
      name: "provider_toggle_two",
      label: "Provider Toggle Two",
      enabled: true,
      issuer: "https://two.example.com",
      client_id: "client2",
      client_secret: "secret2"
    )

    Setting.local_login_enabled = false
    AuthConfig.stubs(:local_login_enabled?).returns(false)

    patch toggle_admin_sso_provider_url(provider1)

    assert_redirected_to admin_sso_providers_path
    assert_equal I18n.t("admin.sso_providers.toggle.success_disabled"), flash[:notice]
    assert_not provider1.reload.enabled?
  ensure
    Setting.local_login_enabled = original_local_login
    provider1.destroy rescue nil
    provider2.destroy rescue nil
  end

  test "update_settings rejects disabling local login with no sso providers" do
    original_local_login = Setting.local_login_enabled
    AuthConfig.stubs(:sso_providers).returns([])
    Setting.local_login_enabled = true

    patch update_settings_admin_sso_providers_url, params: {
      setting: { local_login_enabled: "0" }
    }

    assert_redirected_to admin_sso_providers_path
    assert_equal I18n.t("admin.sso_providers.update_settings.local_login_disabled_no_sso"), flash[:alert]
    assert Setting.local_login_enabled, "local_login_enabled should remain true"
  ensure
    Setting.local_login_enabled = original_local_login
  end

  test "update_settings allows disabling local login when sso providers exist" do
    original_local_login = Setting.local_login_enabled
    original_sso_auto_redirect = Setting.sso_auto_redirect
    AuthConfig.stubs(:sso_providers).returns([
      { id: "authentik", strategy: "openid_connect", name: "authentik", label: "Sign in with Authentik" }
    ])
    Setting.local_login_enabled = true

    patch update_settings_admin_sso_providers_url, params: {
      setting: { local_login_enabled: "0", sso_auto_redirect: "1" }
    }

    assert_redirected_to admin_sso_providers_path
    assert_equal I18n.t("admin.sso_providers.update_settings.settings_updated"), flash[:notice]
    assert_not Setting.local_login_enabled
    assert Setting.sso_auto_redirect
  ensure
    Setting.local_login_enabled = original_local_login
    Setting.sso_auto_redirect = original_sso_auto_redirect
  end
end
