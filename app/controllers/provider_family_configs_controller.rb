class ProviderFamilyConfigsController < ApplicationController
  before_action :require_admin!
  before_action :set_config, only: [ :edit, :update ]

  def new
    @config = Current.family.provider_family_configs.build(provider_key: params[:provider])
  end

  def create
    @config = Current.family.provider_family_configs.build(config_params)
    if @config.save
      if Provider::ConnectionRegistry.registered?(@config.provider_key)
        # OAuth start is POST-only; route the user through the select page so they
        # initiate the OAuth flow with an explicit form submission.
        redirect_to select_provider_connections_path(provider: @config.provider_key),
                    notice: t("provider.family_configs.saved")
      else
        redirect_to settings_providers_path, notice: t("provider.family_configs.saved")
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    attrs = config_params
    attrs = attrs.except(:client_secret) if attrs[:client_secret].blank? && @config.client_secret.present?

    if @config.update(attrs)
      redirect_to settings_providers_path, notice: t("provider.family_configs.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    Current.family.provider_family_configs.find(params[:id]).destroy
    redirect_to settings_providers_path, notice: t("provider.family_configs.removed")
  end

  private

    def set_config
      @config = Current.family.provider_family_configs.find(params[:id])
    end

    def config_params
      params.require(:provider_family_config).permit(:provider_key, :client_id, :client_secret)
    end
end
