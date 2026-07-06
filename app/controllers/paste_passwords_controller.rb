class PastePasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_paste

  rate_limit to: 20, within: 3.minutes, only: :create,
    with: -> { redirect_back fallback_location: root_path, alert: t("paste_passwords.rate_limited") }

  def new
    @paste_password_form_url = password_form_url
    redirect_to after_unlock_url if !@paste.password_protected? || paste_unlocked?(@paste)
  end

  def create
    if @paste.authenticate_password(params[:password])
      unlock_paste!(@paste)
      redirect_to after_unlock_url, status: :see_other
    else
      @paste_password_form_url = password_form_url
      flash.now[:alert] = t("paste_passwords.invalid")
      render :new, status: :unprocessable_entity
    end
  end

  private
    def set_paste
      @paste = if params[:token].present?
        Paste.find_by_subdomain!(params[:token])
      else
        Paste.find_by_subdomain!(request.host[/\A[^.]+/])
      end
    end

    def after_unlock_url
      params[:token].present? ? paste_path(@paste) : "/"
    end

    def password_form_url
      params[:token].present? ? paste_password_path(@paste) : "/"
    end
end
