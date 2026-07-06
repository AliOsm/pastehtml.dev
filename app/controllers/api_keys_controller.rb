class ApiKeysController < ApplicationController
  before_action :prevent_api_key_token_caching
  before_action :set_api_key, only: :destroy

  rate_limit to: 20, within: 1.hour, only: :create, by: -> { Current.user&.id },
    with: -> { redirect_to api_keys_path, status: :see_other, alert: t("flash.rate_limited") }

  def index
    prepare_api_key_page
    @api_key = Current.user.api_keys.build(name: default_key_name)
  end

  def create
    @api_key = Current.user.api_keys.build(api_key_params)

    if @api_key.save
      @created_api_key_token = @api_key.plain_key
      prepare_api_key_page
      @api_key = Current.user.api_keys.build(name: default_key_name)
      render :index, status: :created
    else
      prepare_api_key_page
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @api_key.revoke!
    redirect_to api_keys_path, status: :see_other, notice: t("api_keys.revoked")
  end

  private
    def set_api_key
      @api_key = Current.user.api_keys.active.find(params[:id])
    end

    def prepare_api_key_page
      @api_keys = Current.user.api_keys.active.includes(:folder).recent
      @folders = Current.user.folders.order(:name)
    end

    def api_key_params
      params.require(:api_key).permit(:name, :folder_id)
    end

    def default_key_name
      t("api_keys.default_name")
    end

    def prevent_api_key_token_caching
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
    end
end
