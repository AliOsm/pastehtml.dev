module McpTools
  # Changes a user-owned paste's settings -- password, custom subdomain,
  # folder -- without touching its content. Every setting is independently
  # optional, but at least one must be supplied, and a "set" argument and its
  # matching "clear" argument are mutually exclusive (the agent must pick one).
  class ConfigurePaste < BaseTool
    tool_name "configure_paste"
    description <<~TEXT.strip
      Change an existing paste's settings without republishing its content: set
      or clear password protection, set or clear a custom_subdomain, or file it
      into (or out of) a folder. At least one setting must be supplied.
      Destructive: clearing password protection exposes the paste to anyone with
      the link -- that is an exposure event even if a new password is set
      later -- and replacing a custom_subdomain immediately releases the old one
      for anyone else to claim. Supplying folder_name for a folder that does not
      exist creates it (the result sets folder_created: true). Only pastes owned
      by the authenticated user can be configured.
    TEXT

    input_schema(
      type: "object",
      properties: {
        token: { type: "string", description: "The paste's token." },
        password: { type: "string", description: "Set (or replace) the paste's password. Conflicts with clear_password." },
        clear_password: { type: "boolean", description: "Remove password protection, exposing the paste. Conflicts with password." },
        custom_subdomain: { type: "string", description: "Set (or replace) the paste's custom subdomain, releasing any previous one. Conflicts with clear_custom_subdomain." },
        clear_custom_subdomain: { type: "boolean", description: "Remove the custom subdomain, releasing it. Conflicts with custom_subdomain." },
        folder_id: { type: "integer", description: "File the paste into this folder (by id). Conflicts with clear_folder." },
        folder_name: { type: "string", description: "File the paste into this folder (by name); creates it if missing. Conflicts with clear_folder." },
        clear_folder: { type: "boolean", description: "Remove the paste from its folder. Conflicts with folder_id/folder_name." }
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
        folder_created: { type: "boolean" },
        password_protected: { type: "boolean" }
      },
      required: %w[ token title url live_url raw_url render_url markdown_url folder folder_created password_protected ]
    )

    annotations(
      read_only_hint: false,
      destructive_hint: true,
      idempotent_hint: true,
      open_world_hint: false
    )

    class << self
      def call(token:, password: nil, clear_password: nil, custom_subdomain: nil, clear_custom_subdomain: nil,
                folder_id: nil, folder_name: nil, clear_folder: nil, server_context:)
        user = user_for(server_context)

        paste = user.pastes.find_by(token: token)
        return paste_not_found(token) if paste.nil?

        settings_error = validate_settings(
          password:, clear_password:, custom_subdomain:, clear_custom_subdomain:, folder_id:, folder_name:, clear_folder:
        )
        return settings_error if settings_error

        result = nil
        Paste.transaction do
          apply_password!(paste, password, clear_password)
          apply_custom_subdomain!(paste, custom_subdomain, clear_custom_subdomain)

          folder_created, folder_error = apply_folder!(paste, user, folder_id, folder_name, clear_folder)
          if folder_error
            result = folder_error
            raise ActiveRecord::Rollback
          end

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
        def paste_not_found(token)
          failure(code: "paste_not_found", message: "No paste with token #{token.inspect}.", field: "token")
        end

        def validate_settings(password:, clear_password:, custom_subdomain:, clear_custom_subdomain:, folder_id:, folder_name:, clear_folder:)
          unless settings_supplied?(
            password:, clear_password:, custom_subdomain:, clear_custom_subdomain:, folder_id:, folder_name:, clear_folder:
          )
            return failure(code: "no_settings_provided", message: "Supply at least one setting to change.")
          end

          if password.present? && clear_password
            return failure(code: "conflicting_arguments", message: "password and clear_password cannot both be given.", field: "clear_password")
          end

          if custom_subdomain.present? && clear_custom_subdomain
            return failure(code: "conflicting_arguments", message: "custom_subdomain and clear_custom_subdomain cannot both be given.", field: "clear_custom_subdomain")
          end

          if (folder_id.present? || folder_name.present?) && clear_folder
            return failure(code: "conflicting_arguments", message: "folder_id/folder_name and clear_folder cannot both be given.", field: "clear_folder")
          end

          nil
        end

        def settings_supplied?(password:, clear_password:, custom_subdomain:, clear_custom_subdomain:, folder_id:, folder_name:, clear_folder:)
          password.present? || !clear_password.nil? || custom_subdomain.present? ||
            !clear_custom_subdomain.nil? || folder_id.present? || folder_name.present? || !clear_folder.nil?
        end

        def apply_password!(paste, password, clear_password)
          if clear_password
            paste.password_digest = nil
          elsif password.present?
            paste.password = password
          end
        end

        def apply_custom_subdomain!(paste, custom_subdomain, clear_custom_subdomain)
          if clear_custom_subdomain
            paste.custom_subdomain = nil
          elsif custom_subdomain.present?
            paste.custom_subdomain = custom_subdomain
          end
        end

        # Returns [folder_created, error]; mutates paste.folder in place.
        def apply_folder!(paste, user, folder_id, folder_name, clear_folder)
          if clear_folder
            paste.folder = nil
            return [ false, nil ]
          end

          return [ false, nil ] unless folder_id.present? || folder_name.present?

          folder, folder_created, folder_error = resolve_or_create_folder(user, folder_id, folder_name)
          return [ false, folder_error ] if folder_error

          paste.folder = folder
          [ folder_created, nil ]
        end
    end
  end
end
