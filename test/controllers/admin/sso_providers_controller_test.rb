require "test_helper"

class Admin::SsoProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:sure_support_staff)
  end

  test "update_settings rejects disabling local login with no sso providers" do
    AuthConfig.stubs(:sso_providers).returns([])

    patch update_settings_admin_sso_providers_url, params: {
      setting: { local_login_enabled: "0" }
    }

    assert_redirected_to admin_sso_providers_path
    assert_equal "You cannot disable local login while no SSO providers are configured. Add and enable an SSO provider first.", flash[:alert]
    assert Setting.local_login_enabled, "local_login_enabled should remain true"
  end

  test "update_settings allows disabling local login when sso providers exist" do
    AuthConfig.stubs(:sso_providers).returns([
      { id: "authentik", strategy: "openid_connect", name: "authentik", label: "Sign in with Authentik" }
    ])
    Setting.local_login_enabled = true

    patch update_settings_admin_sso_providers_url, params: {
      setting: { local_login_enabled: "0", sso_auto_redirect: "1" }
    }

    assert_redirected_to admin_sso_providers_path
    assert_equal "SSO settings were successfully updated.", flash[:notice]
    assert_not Setting.local_login_enabled
    assert Setting.sso_auto_redirect
  ensure
    Setting.local_login_enabled = true
    Setting.sso_auto_redirect = false
  end
end
