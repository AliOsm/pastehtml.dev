module McpTools
  # Lists the authenticated user's pastes, newest first, 20 per page, optionally
  # filtered to a single folder. Never loads paste bodies (up to 2 MB each) --
  # the byte size is projected instead via the with_content_size scope.
  class ListPastes < BaseTool
    PAGE_SIZE = 20

    tool_name "list_pastes"
    description <<~TEXT.strip
      List the authenticated user's pastes, newest first, #{PAGE_SIZE} per page. \
      Optionally filter to a single folder by folder_id or folder_name (an unknown \
      folder is an error). Read-only. Returns metadata and URLs only -- not the \
      paste content -- with the total count for pagination.
    TEXT

    input_schema(
      type: "object",
      properties: {
        folder_id: { type: "integer", description: "Optional: only pastes in this folder." },
        folder_name: { type: "string", description: "Optional: only pastes in the folder with this name (case-insensitive)." },
        page: { type: "integer", minimum: 1, description: "1-based page number; page size is fixed at #{PAGE_SIZE}." }
      },
      required: [],
      additionalProperties: false
    )

    output_schema(
      type: "object",
      properties: {
        pastes: {
          type: "array",
          items: {
            type: "object",
            properties: {
              token: { type: "string" },
              title: { type: "string" },
              url: { type: "string" },
              live_url: { type: "string" },
              folder: {
                type: [ "object", "null" ],
                properties: { id: { type: "integer" }, name: { type: "string" } }
              },
              views_count: { type: "integer" },
              content_bytes: { type: "integer" },
              created_at: { type: "string" },
              updated_at: { type: "string" }
            },
            required: %w[ token title url live_url folder views_count content_bytes created_at updated_at ]
          }
        },
        page: { type: "integer" },
        total_count: { type: "integer" }
      },
      required: %w[ pastes page total_count ]
    )

    annotations(
      read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
    )

    class << self
      def call(folder_id: nil, folder_name: nil, page: nil, server_context:)
        user = user_for(server_context)

        folder, folder_error = owned_folder(user, folder_id, folder_name)
        return folder_error if folder_error

        page = normalize_page(page)
        scope = folder ? user.pastes.where(folder_id: folder.id) : user.pastes

        ok(
          pastes: page_of(scope, page).map { |paste| paste_summary(paste) },
          page: page,
          total_count: scope.count
        )
      end

      private
        def normalize_page(page)
          page = page.to_i
          page < 1 ? 1 : page
        end

        def page_of(scope, page)
          scope
            .with_content_size
            .recent
            .includes(:folder)
            .offset((page - 1) * PAGE_SIZE)
            .limit(PAGE_SIZE)
        end

        def paste_summary(paste)
          {
            token: paste.token,
            title: paste.display_title,
            url: app_url("/p/#{paste.token}"),
            live_url: live_url_for(paste),
            folder: folder_ref(paste),
            views_count: paste.views_count,
            content_bytes: paste["content_bytes"].to_i,
            created_at: paste.created_at.iso8601,
            updated_at: paste.updated_at.iso8601
          }
        end
    end
  end
end
