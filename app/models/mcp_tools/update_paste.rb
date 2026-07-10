module McpTools
  # Republishes an existing, user-owned paste's content. `format` is required
  # and explicit for the same reason as create_paste: `Paste#republish` keeps
  # the paste's previously stored filename when none is supplied, so inferring
  # nothing and instead always deriving a filename from `format` (or a
  # supplied `filename` whose extension must agree with it) is the only way to
  # guarantee HTML content is never accidentally run through the Markdown
  # renderer (or vice versa) because an old filename disagreed with the new
  # content.
  class UpdatePaste < BaseTool
    tool_name "update_paste"
    description <<~TEXT.strip
      Republish an existing paste's content, identified by token. Destructive:
      this irreversibly overwrites the paste's current content -- there is no
      version history to roll back to. `format` is required -- "html" stores
      the content as-is, "markdown" renders it to a branded HTML page -- and is
      always used to (re)derive the filename that drives rendering, never the
      paste's previously stored filename. If `filename` is given its extension
      must match `format`. Only pastes owned by the authenticated user can be
      updated. Settings (password, custom_subdomain, folder) are untouched --
      use configure_paste for those.
    TEXT

    input_schema(
      type: "object",
      properties: {
        token: { type: "string", description: "The paste's token." },
        content: {
          type: "string",
          description: "The new paste body: HTML source when format is \"html\", GitHub-Flavored Markdown when format is \"markdown\"."
        },
        format: {
          type: "string",
          enum: [ "html", "markdown" ],
          description: "Required. \"html\" stores content verbatim; \"markdown\" renders it to a branded self-contained HTML page. Always drives the filename used for rendering -- never inferred from the paste's stored filename."
        },
        filename: {
          type: "string",
          description: "Optional filename; its extension must match format (.html/.htm for html, .md/.markdown for markdown). For markdown it seeds the rendered <title>."
        }
      },
      required: [ "token", "content", "format" ],
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
        password_protected: { type: "boolean" }
      },
      required: %w[ token title url live_url raw_url render_url markdown_url folder password_protected ]
    )

    annotations(
      read_only_hint: false,
      destructive_hint: true,
      idempotent_hint: false,
      open_world_hint: false
    )

    class << self
      def call(token:, content:, format:, filename: nil, server_context:)
        user = user_for(server_context)

        paste = user.pastes.find_by(token: token)
        return paste_not_found(token) if paste.nil?

        resolved_filename, filename_error = resolve_filename(format, filename)
        return filename_error if filename_error

        if paste.republish(content: content, original_filename: resolved_filename)
          ok(paste_summary(paste))
        else
          validation_error(paste)
        end
      end

      private
        def paste_not_found(token)
          failure(code: "paste_not_found", message: "No paste with token #{token.inspect}.", field: "token")
        end
    end
  end
end
