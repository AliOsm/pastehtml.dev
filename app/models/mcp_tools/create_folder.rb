module McpTools
  # Creates a new, empty folder owned by the authenticated user. Folder names
  # are unique per user, case-insensitively (model validation).
  class CreateFolder < BaseTool
    tool_name "create_folder"
    description <<~TEXT.strip
      Create a new, empty folder owned by the authenticated user. Folder names
      must be unique per user (case-insensitive) -- a duplicate name is a
      validation error.
    TEXT

    input_schema(
      type: "object",
      properties: {
        name: { type: "string", description: "The folder's name." }
      },
      required: [ "name" ],
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
      idempotent_hint: false,
      open_world_hint: false
    )

    class << self
      def call(name:, server_context:)
        user = user_for(server_context)
        folder = user.folders.new(name: name)

        translating_uniqueness_race(folder, attribute: :name) do
          if folder.save
            ok(id: folder.id, name: folder.name, pastes_count: 0)
          else
            validation_error(folder)
          end
        end
      end
    end
  end
end
