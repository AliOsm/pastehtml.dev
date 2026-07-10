module McpTools
  # Fetches a single user-owned paste's metadata and content. The returned
  # `content` is always the stored HTML -- Markdown ingests are rendered to
  # HTML at create/update time and the original Markdown source is never
  # retained, so there is no lossless way back to it. `include_markdown` opts
  # into a best-effort, lossy HTML-to-Markdown conversion (the same one behind
  # GET /p/:token/markdown) for callers that want a rough Markdown view anyway.
  class GetPaste < BaseTool
    tool_name "get_paste"
    description <<~TEXT.strip
      Fetch a single paste owned by the authenticated user, by token: its
      metadata, URLs, and content. `content` is always the stored HTML --
      Markdown-created pastes are rendered to HTML at ingest and the original
      Markdown source is not retained. Set include_markdown: true to also get a
      best-effort, lossy HTML-to-Markdown conversion of the content (the same
      conversion behind the /markdown URL); it is not the original source.
      Read-only.
    TEXT

    input_schema(
      type: "object",
      properties: {
        token: { type: "string", description: "The paste's token." },
        include_markdown: {
          type: "boolean",
          description: "When true, also return a best-effort, lossy HTML-to-Markdown conversion of content. Default false."
        }
      },
      required: [ "token" ],
      additionalProperties: false
    )

    output_schema(
      type: "object",
      properties: {
        token: { type: "string" },
        title: { type: "string" },
        url: { type: "string" },
        live_url: { type: "string" },
        raw_url: { type: "string" },
        render_url: { type: "string" },
        markdown_url: { type: "string" },
        folder: {
          type: [ "object", "null" ],
          properties: { id: { type: "integer" }, name: { type: "string" } }
        },
        password_protected: { type: "boolean" },
        content: { type: "string", description: "The stored HTML -- never the original Markdown source." },
        content_bytes: { type: "integer" },
        markdown: { type: "string", description: "Present only when include_markdown was true: a best-effort, lossy HTML-to-Markdown conversion." }
      },
      required: %w[ token title url live_url raw_url render_url markdown_url folder password_protected content content_bytes ]
    )

    annotations(
      read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
    )

    class << self
      def call(token:, include_markdown: false, server_context:)
        user = user_for(server_context)

        paste = user.pastes.find_by(token: token)
        return paste_not_found(token) if paste.nil?

        payload = paste_summary(paste).merge(
          content: paste.content,
          content_bytes: paste.content.bytesize
        )
        payload[:markdown] = paste.to_markdown if include_markdown

        ok(payload)
      end

      private
        def paste_not_found(token)
          failure(code: "paste_not_found", message: "No paste with token #{token.inspect}.", field: "token")
        end
    end
  end
end
