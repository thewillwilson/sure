class TruelayerItem::AccountSetup
  Result = Struct.new(:pending_accounts, :success?, keyword_init: true)

  def initialize(truelayer_item:, truelayer_account:, account_id: nil, create_account: false, family:)
    @truelayer_item    = truelayer_item
    @truelayer_account = truelayer_account
    @account_id        = account_id
    @create_account    = create_account
    @family            = family
  end

  def call
    ActiveRecord::Base.transaction do
      if @account_id.present?
        account = @family.accounts.find(@account_id)
        AccountProvider.create!(account: account, provider: @truelayer_account)
      elsif @create_account
        @truelayer_account.create_linked_account!(family: @family)
      else
        @truelayer_account.update!(setup_skipped: true)
      end
    end

    pending = @truelayer_item.truelayer_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil }, setup_skipped: false)

    Result.new(pending_accounts: pending, success?: true)
  end
end
