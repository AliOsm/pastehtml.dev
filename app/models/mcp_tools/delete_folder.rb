module McpTools
  # Destroys a folder owned by the authenticated user. Pastes are never
  # deleted -- the folder's pastes are nullified (survive, unfiled) -- and any
  # API keys scoped to the folder are revoked, both via Folder's own
  # `dependent: :nullify`/`before_destroy` callbacks. `confirm: true` is
  # required; it is accidental-action friction (the agent supplies it itself),
  # not a security boundary -- the meaningful protections are the honest
  # destructive_hint annotation and the client's own approval flow.
  class DeleteFolder < BaseTool
    tool_name "delete_folder"
    description <<~TEXT.strip
      Permanently delete a folder owned by the authenticated user. Destructive
      and irreversible: pastes filed in the folder are NOT deleted -- they
      survive, unfiled (their folder_id becomes null) -- and any API keys
      scoped to this folder are revoked. Requires confirm: true; any other
      value is refused with no changes made.
    TEXT

    input_schema(
      type: "object",
      properties: {
        folder_id: { type: "integer", description: "The id of the folder to delete." },
        confirm: { type: "boolean", description: "Must be true to proceed. Any other value is refused." }
      },
      required: [ "folder_id", "confirm" ],
      additionalProperties: false
    )

    output_schema(
      type: "object",
      properties: {
        deleted: { type: "boolean" },
        unfiled_pastes_count: { type: "integer", description: "Pastes that were in this folder and are now unfiled (not deleted)." },
        revoked_api_keys_count: { type: "integer", description: "API keys scoped to this folder that were revoked." }
      },
      required: %w[ deleted unfiled_pastes_count revoked_api_keys_count ]
    )

    annotations(
      read_only_hint: false,
      destructive_hint: true,
      idempotent_hint: false,
      open_world_hint: false
    )

    class << self
      def call(folder_id:, confirm:, server_context:)
        user = user_for(server_context)
        folder = user.folders.find_by(id: folder_id)
        return folder_not_found(folder_id) if folder.nil?

        return confirmation_required unless confirm == true

        unfiled_pastes_count = folder.pastes.count
        revoked_api_keys_count = folder.api_keys.active.count

        folder.destroy!

        ok(deleted: true, unfiled_pastes_count: unfiled_pastes_count, revoked_api_keys_count: revoked_api_keys_count)
      end

      private
        def folder_not_found(folder_id)
          failure(code: "folder_not_found", message: "No folder with id #{folder_id}.", field: "folder_id")
        end

        def confirmation_required
          failure(
            code: "confirmation_required",
            message: "Set confirm: true to permanently delete this folder.",
            field: "confirm"
          )
        end
    end
  end
end
