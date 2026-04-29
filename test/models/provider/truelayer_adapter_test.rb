require "test_helper"

class Provider::TruelayerAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    family = families(:dylan_family)
    item = TruelayerItem.create!(
      family: family,
      name: "Adapter Test",
      client_id: "cid",
      client_secret: "csec",
      access_token: "tok"
    )
    @account = accounts(:depository)
    @truelayer_account = TruelayerAccount.create!(
      truelayer_item: item,
      account_id: "tl_adapter_001",
      account_kind: "account",
      name: "Current Account",
      currency: "GBP"
    )
    AccountProvider.create!(account: @account, provider: @truelayer_account)
    @adapter = Provider::TruelayerAdapter.new(@truelayer_account, account: @account)
  end

  def adapter
    @adapter
  end

  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  test "returns correct provider name" do
    assert_equal "truelayer", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "TruelayerAccount", @adapter.provider_type
  end

  test "returns truelayer item" do
    assert_equal @truelayer_account.truelayer_item, @adapter.item
  end

  test "returns account" do
    assert_equal @account, @adapter.account
  end

  test "can_delete_holdings? returns false" do
    assert_equal false, @adapter.can_delete_holdings?
  end
end
