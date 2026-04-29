class TruelayerItemsController < ApplicationController
  before_action :set_truelayer_item, only: [ :update, :destroy, :sync, :reauthorize, :setup_accounts, :complete_account_setup, :reset_skipped ]
  before_action :require_admin!, only: [ :new, :create, :authorize, :update, :destroy, :sync, :reauthorize, :setup_accounts, :complete_account_setup, :reset_skipped, :select_existing_account, :link_existing_account ]
  skip_before_action :verify_authenticity_token, only: [ :callback ]

  def new
    @credentials_configured = Current.family.truelayer_items.where.not(client_id: nil).exists?
    @truelayer_items = Current.family.truelayer_items.where.not(access_token: nil)
  end

  def create
    @truelayer_item = Current.family.truelayer_items.build(credential_params)
    @truelayer_item.name ||= "TrueLayer Connection"

    if @truelayer_item.save
      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      redirect_to settings_providers_path, alert: @truelayer_item.errors.full_messages.to_sentence, status: :see_other
    end
  end

  def update
    if @truelayer_item.update(credential_params.reject { |_, v| v.blank? })
      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      redirect_to settings_providers_path, alert: @truelayer_item.errors.full_messages.to_sentence, status: :see_other
    end
  end

  def destroy
    results = @truelayer_item.unlink_all!(dry_run: false)
    if results.any? { |r| r[:error] }
      redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
      return
    end
    @truelayer_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    unless @truelayer_item.syncing?
      @truelayer_item.sync_later
    end

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@truelayer_item),
          partial: "truelayer_items/truelayer_item",
          locals: { truelayer_item: @truelayer_item }
        )
      end
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Starts OAuth flow using the family's saved credentials
  def authorize
    credentials = Current.family.truelayer_items.where.not(client_id: nil).order(:created_at).last

    unless credentials&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials"), status: :see_other
      return
    end

    # Reuse an existing unconnected stub rather than accumulating orphans,
    # but always refresh credentials in case they were rotated since the stub was created
    @truelayer_item = Current.family.truelayer_items.where(access_token: nil, client_id: credentials.client_id).first
    if @truelayer_item
      @truelayer_item.update!(client_secret: credentials.client_secret, sandbox: credentials.sandbox)
    else
      @truelayer_item = Current.family.truelayer_items.create!(
        name:          "TrueLayer Connection",
        client_id:     credentials.client_id,
        client_secret: credentials.client_secret,
        sandbox:       credentials.sandbox
      )
    end

    nonce = SecureRandom.hex(32)
    session[:truelayer_oauth_pending] = { "item_id" => @truelayer_item.id.to_s, "state" => nonce, "admin" => true }
    redirect_to authorize_url(@truelayer_item, nonce), allow_other_host: true
  rescue => e
    Rails.logger.error "TrueLayer authorize error: #{e.message}"
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def callback
    pending = session.delete(:truelayer_oauth_pending)
    unless pending && pending["state"] == params[:state]
      redirect_to settings_providers_path, alert: t(".authorization_failed")
      return
    end

    unless pending["admin"]
      redirect_to settings_providers_path, alert: t(".authorization_failed")
      return
    end

    @truelayer_item = Current.family.truelayer_items.find(pending["item_id"])

    unless params[:code].present?
      redirect_to settings_providers_path, alert: t(".authorization_failed")
      return
    end

    result = truelayer_provider(@truelayer_item).exchange_code(
      code:         params[:code],
      redirect_uri: callback_truelayer_items_url
    )

    if pending["type"] == "reauth"
      @truelayer_item.update!(
        access_token:     result[:access_token],
        refresh_token:    result[:refresh_token],
        token_expires_at: Time.current + result[:expires_in].to_i.seconds,
        status:           :good
      )
      redirect_to settings_providers_path, notice: t(".reauth_success"), status: :see_other
    else
      @truelayer_item.update!(
        access_token:        result[:access_token],
        refresh_token:       result[:refresh_token],
        token_expires_at:    Time.current + result[:expires_in].to_i.seconds,
        last_psu_ip:         request.remote_ip,
        status:              :good,
        pending_account_setup: true
      )
      @truelayer_item.sync_later
      redirect_to accounts_path, notice: t(".connect_success"), status: :see_other
    end
  rescue => e
    Rails.logger.error "TrueLayer callback error: #{e.message}"
    redirect_to settings_providers_path, alert: t(".authorization_failed")
  end

  def setup_accounts
    if @truelayer_item.syncing?
      redirect_to settings_providers_path, notice: t(".syncing"), status: :see_other
      return
    end

    @truelayer_accounts = @truelayer_item.truelayer_accounts
                            .left_joins(:account_provider)
                            .where(account_providers: { id: nil }, setup_skipped: false)
    @existing_accounts = Current.family.accounts.where.not(status: :pending_deletion).alphabetically
  end

  def complete_account_setup
    if params[:account_id] == ""
      redirect_to setup_accounts_truelayer_item_path(@truelayer_item),
                  alert: t(".select_account_required"),
                  status: :see_other
      return
    end

    truelayer_account = @truelayer_item.truelayer_accounts.find(params[:truelayer_account_id])

    result = TruelayerItem::AccountSetup.new(
      truelayer_item:    @truelayer_item,
      truelayer_account: truelayer_account,
      account_id:        params[:account_id],
      create_account:    params[:create_account] == "true",
      family:            Current.family
    ).call

    if result.pending_accounts.any?
      redirect_to setup_accounts_truelayer_item_path(@truelayer_item), status: :see_other
    else
      @truelayer_item.update!(pending_account_setup: false)
      @truelayer_item.sync_later(window_start_date: 90.days.ago.to_date)
      redirect_to accounts_path, notice: t(".success"), status: :see_other
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to setup_accounts_truelayer_item_path(@truelayer_item), alert: e.message, status: :see_other
  end

  def reset_skipped
    @truelayer_item.truelayer_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil }, setup_skipped: true)
      .update_all(setup_skipped: false)
    @truelayer_item.update!(pending_account_setup: true)
    redirect_to setup_accounts_truelayer_item_path(@truelayer_item), status: :see_other
  end

  def reauthorize
    nonce = SecureRandom.hex(32)
    session[:truelayer_oauth_pending] = { "item_id" => @truelayer_item.id.to_s, "state" => nonce, "type" => "reauth", "admin" => true }

    if @truelayer_item.refresh_token.present?
      result = truelayer_provider(@truelayer_item).generate_reauth_uri(
        refresh_token: @truelayer_item.refresh_token,
        redirect_uri:  callback_truelayer_items_url,
        state:         nonce
      )
      redirect_to result[:result], allow_other_host: true and return if result[:success]
    end

    redirect_to authorize_url(@truelayer_item, nonce), allow_other_host: true
  rescue => e
    Rails.logger.error "TrueLayer reauthorize error: #{e.message}"
    redirect_to authorize_url(@truelayer_item, nonce), allow_other_host: true
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_truelayer_accounts = Current.family.truelayer_items
      .includes(truelayer_accounts: [ :account_provider ])
      .flat_map(&:truelayer_accounts)
      .select { |ta| ta.account_provider.nil? }
      .sort_by { |ta| ta.name.to_s }
  end

  def link_existing_account
    unless params[:truelayer_account_id].present?
      redirect_to accounts_path, alert: t("truelayer_items.link_existing_account.no_account_selected"), status: :see_other
      return
    end

    @account = Current.family.accounts.find(params[:account_id])
    truelayer_account = TruelayerAccount.joins(truelayer_item: :family)
                          .find_by!(id: params[:truelayer_account_id], truelayer_items: { family_id: Current.family.id })

    ActiveRecord::Base.transaction do
      AccountProvider.create!(account: @account, provider: truelayer_account)
    end

    redirect_to accounts_path, notice: t(".success"), status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    redirect_to accounts_path, alert: e.message, status: :see_other
  end

  private

    def set_truelayer_item
      @truelayer_item = Current.family.truelayer_items.find(params[:id])
    end

    def credential_params
      params.require(:truelayer_item).permit(:name, :client_id, :client_secret, :sandbox)
    end

    def truelayer_provider(item)
      Provider::Truelayer.new(
        client_id:     item.client_id,
        client_secret: item.client_secret,
        sandbox:       item.sandbox?
      )
    end

    def authorize_url(item, nonce)
      provider = truelayer_provider(item)
      provider.auth_url(
        redirect_uri: callback_truelayer_items_url,
        state:        nonce
      )
    end
end
