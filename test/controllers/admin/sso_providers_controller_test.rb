require "test_helper"

class Admin::SsoProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:sure_support_staff)
  end

  test "update_settings rejects disabling local login with no sso providers" do
    original_local_login = Setting.local_login_enabled
    AuthConfig.stubs(:sso_providers).returns([])

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
