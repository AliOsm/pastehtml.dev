module McpTools
  # Renames a folder owned by the authenticated user. Uniqueness (per user,
  # case-insensitive) is enforced by the same model validation as create_folder.
  class RenameFolder < BaseTool
    tool_name "rename_folder"
    description <<~TEXT.strip
      Rename a folder owned by the authenticated user. Folder names must be
      unique per user (case-insensitive) -- a duplicate name is a validation
      error. Only folders owned by the authenticated user can be renamed.
    TEXT

    input_schema(
      type: "object",
      properties: {
        folder_id: { type: "integer", description: "The id of the folder to rename." },
        name: { type: "string", description: "The folder's new name." }
      },
      required: [ "folder_id", "name" ],
      additionalProperties: false
    )

    output_schema(
      type: "object",
      properties: {
        id: { type: "integer" },
        name: { type: "string" },
        pastes_count: { type: "integer" }
      },
      required: %w[ id name pastes_count ]
    )

    annotations(
      read_only_hint: false,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
    )

    class << self
      def call(folder_id:, name:, server_context:)
        user = user_for(server_context)
        folder = user.folders.find_by(id: folder_id)
        return folder_not_found(folder_id) if folder.nil?

        translating_uniqueness_race(folder, attribute: :name) do
          if folder.update(name: name)
            ok(id: folder.id, name: folder.name, pastes_count: folder.pastes.count)
          else
            validation_error(folder)
          end
        end
      end

      private
        def folder_not_found(folder_id)
          failure(code: "folder_not_found", message: "No folder with id #{folder_id}.", field: "folder_id")
        end
    end
  end
end
