class FoldersController < ApplicationController
  before_action :set_folder, only: %i[ show edit update destroy ]

  rate_limit to: 30, within: 1.minute, only: :create, by: -> { Current.user&.id },
    with: -> { redirect_to pastes_path, status: :see_other, alert: t("flash.rate_limited") }

  def index
    redirect_to pastes_path
  end

  def show
    @folders = Current.user.folders.order(:name)
    @pastes = @folder.pastes.with_content_size.includes(:folder).recent
    render "pastes/index"
  end

  def new
    @folder = Current.user.folders.build
  end

  def create
    @folder = Current.user.folders.build(folder_params)

    if @folder.save
      redirect_to folder_path(@folder), status: :see_other, notice: t("folders.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @folder.update(folder_params)
      redirect_to folder_path(@folder), status: :see_other, notice: t("folders.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @folder.destroy
    redirect_to pastes_path, status: :see_other, notice: t("folders.destroyed")
  end

  private
    def set_folder
      @folder = Current.user.folders.find(params[:id])
    end

    def folder_params
      params.require(:folder).permit(:name)
    end
end
