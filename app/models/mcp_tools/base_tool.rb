module McpTools
  # Shared conventions for every PasteHTML MCP tool. Subclasses set the DSL
  # metadata (tool_name/description/input_schema/output_schema/annotations) and
  # implement `self.call`, leaning on the helpers here so results and errors
  # come out in exactly one shape.
  #
  # Success is a structured result matching the tool's output_schema (validated
  # server-side by the SDK, see McpController). Domain failures -- ownership,
  # not-found, name conflicts, model validation -- are tool ERROR responses in a
  # single stable shape: { code:, message:, field? }. They are never raised
  # Ruby exceptions: an exception would surface as a JSON-RPC internal/protocol
  # error the agent cannot correct, whereas a structured error is model-correctable.
  #
  # Tools have no request context, so every URL is derived from the trusted
  # McpOauth::CONFIG[:issuer] (never from request headers) -- the same canonical
  # origin the OAuth issuer/audience use. App paths mirror config/routes.rb
  # (`/p/:token[/raw|/render|/markdown]`); the per-paste live origin mirrors
  # PasteLiveUrl but sources scheme/host/port from the issuer instead of the
  # (absent) request.
  class BaseTool < MCP::Tool
    # Maps an offending ActiveModel attribute to the tool argument that carries
    # it, so a model validation error points the agent at the arg it passed.
    FIELD_FOR_ATTRIBUTE = {
      "content" => "content",
      "custom_subdomain" => "custom_subdomain",
      "password" => "password",
      "original_filename" => "filename",
      "folder" => "folder_id"
    }.freeze

    # format => synthetic filename used when a tool omits `filename`, and the
    # extension that format's filename must carry when one is supplied. Shared
    # by every tool that republishes content (create_paste, update_paste) so
    # `Paste.render_content`/`Paste#republish` are always keyed on a filename
    # derived from the required `format` argument -- never inferred or left to
    # fall back to a paste's previously stored filename.
    SYNTHETIC_FILENAME = { "html" => "paste.html", "markdown" => "paste.md" }.freeze
    EXTENSION_FOR_FORMAT = { "html" => Paste::HTML_EXTENSION, "markdown" => Paste::MARKDOWN_EXTENSION }.freeze

    class << self
      private

      # The token's user, from the controller's server_context. Works whether
      # server_context is the raw Hash (unit tests call tools directly) or the
      # SDK's MCP::ServerContext wrapper (which delegates `[]` to that Hash).
      def user_for(server_context)
        server_context[:user]
      end

      # Success: structured content plus a JSON text mirror for clients that
      # only read `content`.
      def ok(structured)
        MCP::Tool::Response.new(
          [ { type: "text", text: JSON.generate(structured) } ],
          structured_content: structured
        )
      end

      # The one error shape. `field` is included only when an offending argument
      # exists (the spec's "offending_arg_or_omitted").
      def failure(code:, message:, field: nil)
        payload = { code: code, message: message }
        payload[:field] = field.to_s if field.present?

        MCP::Tool::Response.new(
          [ { type: "text", text: message } ],
          error: true,
          structured_content: payload
        )
      end

      # A model's first validation error, rendered into the error shape with the
      # argument that owns it.
      def validation_error(record)
        error = record.errors.first
        attribute = error.attribute.to_s
        failure(
          code: "validation_failed",
          message: error.full_message,
          field: FIELD_FOR_ATTRIBUTE.fetch(attribute, attribute)
        )
      end

      # Look up a folder the user owns, by id or by (case-insensitive) name, for
      # read-side filtering. Returns [folder_or_nil, error_or_nil]; an unknown
      # (or another user's) folder is a not-found error, never a silent empty list.
      def owned_folder(user, folder_id, folder_name)
        if folder_id.present?
          folder = user.folders.find_by(id: folder_id)
          return [ nil, failure(code: "folder_not_found", message: "No folder with id #{folder_id}.", field: "folder_id") ] if folder.nil?

          [ folder, nil ]
        elsif folder_name.present?
          folder = user.folders.where("LOWER(name) = ?", folder_name.to_s.strip.downcase).first
          return [ nil, failure(code: "folder_not_found", message: "No folder named #{folder_name.to_s.strip.inspect}.", field: "folder_name") ] if folder.nil?

          [ folder, nil ]
        else
          [ nil, nil ]
        end
      end

      # { id, name } for a paste's folder, or nil when unfiled.
      def folder_ref(paste)
        paste.folder && { id: paste.folder_id, name: paste.folder.name }
      end

      # Returns [filename, error]. A supplied filename must carry the extension
      # `format` implies; otherwise a synthetic name drives render_content, so
      # rendering always agrees with the caller's explicit `format`.
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

      # Look up a folder the user owns, by id or by (case-insensitive) name, for
      # write-side use, auto-creating a missing named folder. Returns
      # [folder, folder_created, error]. folder_id wins and must belong to the
      # user; a folder_id + folder_name pair naming different folders is a
      # conflict. Shared by create_paste and configure_paste.
      def resolve_or_create_folder(user, folder_id, folder_name)
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

      def issuer
        McpOauth::CONFIG[:issuer]
      end

      def app_url(path)
        "#{issuer}#{path}"
      end

      # The per-paste origin, e.g. https://<subdomain>.pastehtml.dev/ -- scheme,
      # host, and non-default port taken from the issuer.
      def live_url_for(paste)
        uri = URI.parse(issuer)
        default_port = uri.scheme == "https" ? 443 : 80
        port = uri.port && uri.port != default_port ? ":#{uri.port}" : ""
        "#{uri.scheme}://#{paste.public_subdomain.downcase}.#{uri.host}#{port}/"
      end

      # The full create/update success payload for a single paste.
      def paste_detail(paste, folder_created:)
        {
          token: paste.token,
          title: paste.display_title,
          url: app_url("/p/#{paste.token}"),
          live_url: live_url_for(paste),
          raw_url: app_url("/p/#{paste.token}/raw"),
          render_url: app_url("/p/#{paste.token}/render"),
          markdown_url: app_url("/p/#{paste.token}/markdown"),
          folder: folder_ref(paste),
          folder_created: folder_created,
          password_protected: paste.password_protected?
        }
      end

      # paste_detail without the folder_created flag, for tools that never
      # create a folder as a side effect (update_paste, get_paste) -- the field
      # would only ever read false and invite a misleading reading.
      def paste_summary(paste)
        paste_detail(paste, folder_created: false).except(:folder_created)
      end
    end
  end
end
