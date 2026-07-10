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
    SYNTHETIC_FILENAME = { "html" => "paste.html", "markdown" => "paste.md" }.freeze
    EXTENSION_FOR_FORMAT = { "html" => Paste::HTML_EXTENSION, "markdown" => Paste::MARKDOWN_EXTENSION }.freeze

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
          folder, folder_created, folder_error = resolve_folder(user, folder_id, folder_name)
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
        # Returns [filename, error]. A supplied filename must carry the extension
        # `format` implies; otherwise a synthetic name drives render_content.
        def resolve_filename(format, filename)
          return [ SYNTHETIC_FILENAME.fetch(format), nil ] if filename.blank?

          extension = File.extname(filename)
          return [ filename, nil ] if extension.match?(EXTENSION_FOR_FORMAT.fetch(format))

          [ nil, failure(
            code: "filename_format_mismatch",
            message: "filename #{filename.inspect} does not match format #{format.inspect}.",
            field: "filename"
          ) ]
        end

        # Returns [folder, folder_created, error]. folder_id wins and must belong
        # to the user; a folder_id + folder_name pair that name different folders
        # is a conflict; a lone folder_name auto-creates a missing folder.
        def resolve_folder(user, folder_id, folder_name)
          requested_name = folder_name.to_s.strip.presence

          if folder_id.present?
            folder = user.folders.find_by(id: folder_id)
            return [ nil, false, failure(code: "folder_not_found", message: "No folder with id #{folder_id}.", field: "folder_id") ] if folder.nil?

            if requested_name && !folder.name.casecmp?(requested_name)
              return [ nil, false, failure(code: "folder_mismatch", message: "folder_id and folder_name refer to different folders.", field: "folder_name") ]
            end

            [ folder, false, nil ]
          elsif requested_name
            find_or_create_folder(user, requested_name)
          else
            [ nil, false, nil ]
          end
        end

        # Find-or-create by name, tolerant of a concurrent creator, mirroring
        # Api::PastesController#find_or_create_named_folder. Returns
        # [folder, folder_created, error].
        def find_or_create_folder(user, name)
          existing = user.folders.where("LOWER(name) = ?", name.downcase).first
          return [ existing, false, nil ] if existing

          folder = user.folders.new(name: name)
          begin
            Folder.transaction(requires_new: true) { folder.save! }
            [ folder, true, nil ]
          rescue ActiveRecord::RecordInvalid
            [ nil, false, validation_error(folder) ]
          rescue ActiveRecord::RecordNotUnique
            [ user.folders.find_by!("LOWER(name) = ?", name.downcase), false, nil ]
          end
        end

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
