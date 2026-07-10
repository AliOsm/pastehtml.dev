module McpTools
  # Publishes a new paste owned by the token's user.
  #
  # `format` is required and explicit (never inferred): "html" stores the source
  # verbatim, "markdown" renders GitHub-Flavored Markdown to a branded,
  # self-contained HTML page. A supplied `filename` must agree with `format`
  # (its extension is what Paste.render_content keys on); when omitted a
  # synthetic name (paste.html / paste.md) is used so rendering still does the
  # right thing. There is deliberately no `title` argument -- the title is always
  # derived from the content's <title> on save.
  class CreatePaste < BaseTool
    tool_name "create_paste"
    description <<~TEXT.strip
      Create and publish a new paste owned by the authenticated user. Side effect: \
      writes a new, permanent paste (pastes can never be deleted). `format` is \
      required -- "html" stores the content as-is, "markdown" renders it to a \
      branded HTML page. If `filename` is given its extension must match `format`. \
      Supplying `folder_name` for a folder that does not exist creates it (the \
      result sets folder_created: true). Returns the paste's token and its URLs.
    TEXT

    input_schema(
      type: "object",
      properties: {
        content: {
          type: "string",
          description: "The paste body: HTML source when format is \"html\", GitHub-Flavored Markdown when format is \"markdown\"."
        },
        format: {
          type: "string",
          enum: [ "html", "markdown" ],
          description: "Required. \"html\" stores content verbatim; \"markdown\" renders it to a branded self-contained HTML page."
        },
        filename: {
          type: "string",
          description: "Optional filename; its extension must match format (.html/.htm for html, .md/.markdown for markdown). For markdown it seeds the rendered <title>."
        },
        custom_subdomain: {
          type: "string",
          description: "Optional vanity subdomain for the paste's live origin (<custom_subdomain>.pastehtml.dev)."
        },
        password: {
          type: "string",
          description: "Optional password; when set the live paste is gated behind it."
        },
        folder_id: {
          type: "integer",
          description: "Optional id of one of the user's folders to file the paste into."
        },
        folder_name: {
          type: "string",
          description: "Optional folder name; a missing folder is created (result sets folder_created: true)."
        }
      },
      required: [ "content", "format" ],
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
        folder_created: { type: "boolean" },
        password_protected: { type: "boolean" }
      },
      required: %w[ token title url live_url raw_url render_url markdown_url folder folder_created password_protected ]
    )

    annotations(
      read_only_hint: false,
      destructive_hint: false,
      idempotent_hint: false,
      open_world_hint: false
    )

    class << self
      def call(content:, format:, filename: nil, custom_subdomain: nil, password: nil, folder_id: nil, folder_name: nil, server_context:)
        user = user_for(server_context)

        resolved_filename, filename_error = resolve_filename(format, filename)
        return filename_error if filename_error

        result = nil
        Paste.transaction do
          folder, folder_created, folder_error = resolve_or_create_folder(user, folder_id, folder_name)
          if folder_error
            result = folder_error
            raise ActiveRecord::Rollback
          end

          paste = build_paste(user, content, resolved_filename, folder, custom_subdomain, password)
          if paste.save
            result = ok(paste_detail(paste, folder_created: folder_created))
          else
            result = validation_error(paste)
            raise ActiveRecord::Rollback
          end
        end
        result
      end

      private
        def build_paste(user, content, filename, folder, custom_subdomain, password)
          paste = Paste.new(
            content: Paste.render_content(content, filename),
            original_filename: filename,
            user: user,
            folder: folder
          )
          paste.custom_subdomain = custom_subdomain if custom_subdomain.present?
          paste.password = password if password.present?
          paste
        end
    end
  end
end
