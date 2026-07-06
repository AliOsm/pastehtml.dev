module Api
  class FoldersController < BaseController
    before_action :require_account_api_key!

    rate_limit to: 60, within: 1.minute
    rate_limit to: 1000, within: 1.day, name: "daily"

    def index
      folders = visible_folders.left_joins(:pastes)
        .select("folders.*, COUNT(pastes.id) AS pastes_count")
        .group("folders.id")
        .order(:name)

      mark_account_api_key_used!
      render json: { folders: folders.map { |folder| folder_payload(folder) } }
    end

    def create
      return render_scoped_key_cannot_create_folders if account_api_key.folder.present?

      folder = account_user.folders.build(folder_params)

      if folder.save
        mark_account_api_key_used!
        render json: { folder: folder_payload(folder) }, status: :created
      else
        render json: { errors: folder.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private
      def visible_folders
        return account_user.folders.where(id: account_api_key.folder_id) if account_api_key.folder.present?

        account_user.folders
      end

      def folder_params
        if params[:folder].respond_to?(:permit)
          params[:folder].permit(:name)
        else
          params.permit(:name)
        end
      end

      def render_scoped_key_cannot_create_folders
        render json: { error: "This API key is scoped to one folder and cannot create folders." }, status: :forbidden
        false
      end

      def folder_payload(folder)
        {
          id: folder.id,
          name: folder.name,
          pastes_count: folder.try(:pastes_count).to_i
        }
      end
  end
end
