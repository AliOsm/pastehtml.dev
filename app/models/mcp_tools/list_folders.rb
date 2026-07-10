module McpTools
  # Lists the authenticated user's folders, ordered by name, each with its paste
  # count. Read-only, no arguments.
  class ListFolders < BaseTool
    tool_name "list_folders"
    description <<~TEXT.strip
      List the authenticated user's folders, ordered by name, each with the number \
      of pastes filed in it. Read-only; takes no arguments.
    TEXT

    input_schema(
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false
    )

    output_schema(
      type: "object",
      properties: {
        folders: {
          type: "array",
          items: {
            type: "object",
            properties: {
              id: { type: "integer" },
              name: { type: "string" },
              pastes_count: { type: "integer" }
            },
            required: %w[ id name pastes_count ]
          }
        }
      },
      required: %w[ folders ]
    )

    annotations(
      read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
    )

    class << self
      def call(server_context:)
        user = user_for(server_context)
        counts = user.pastes.where.not(folder_id: nil).group(:folder_id).count

        folders = user.folders.order(Arel.sql("LOWER(name), id")).map do |folder|
          { id: folder.id, name: folder.name, pastes_count: counts.fetch(folder.id, 0) }
        end

        ok(folders: folders)
      end
    end
  end
end
