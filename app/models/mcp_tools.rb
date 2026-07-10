# Registry and metadata for the MCP tool catalog. Task 6 fills the registry
# with the real paste/folder tools; for now it is intentionally empty so the
# /mcp endpoint (Task 5) can stand up end-to-end with the transport, auth, and
# scope-enforcement plumbing before any tool exists.
#
# Each tool class is registered with the single OAuth scope required to call
# it ("mcp:read" or "mcp:write"). The controller uses `required_scope` to
# pre-authorize `tools/call` at the HTTP layer (a scope the token lacks is a
# 403 step-up, never a JSON-RPC "unknown tool" error) and `for_scopes` to hand
# the MCP server only the tools the token may see.
module McpTools
  VERSION = "1.0.0"

  # Up-front invariants an agent must know before it acts. Surfaced through the
  # MCP `initialize` handshake as the server `instructions`.
  INSTRUCTIONS = <<~TEXT.strip
    PasteHTML pastes are permanent: there is no delete operation, and a paste \
    can never be removed once created. update_paste overwrites a paste's \
    content irreversibly -- there is no version history to roll back to. The \
    original Markdown source of a paste is not retained; stored content is \
    always the rendered HTML.
  TEXT

  READ_SCOPE = "mcp:read"
  WRITE_SCOPE = "mcp:write"

  # tool class => required scope. A module instance variable, mutated only at
  # boot (Task 6's registrations) and in tests (register a fake tool, then
  # `deregister` it in teardown), read on every request.
  @registry = {}

  class << self
    # Registers a tool class under its required scope. Later registrations of
    # the same class overwrite the earlier scope, so tests can re-register
    # freely.
    def register(tool_class, scope:)
      unless [ READ_SCOPE, WRITE_SCOPE ].include?(scope)
        raise ArgumentError, "unknown scope #{scope.inspect}"
      end

      @registry[tool_class] = scope
    end

    # Removes a tool class from the registry. Used by tests to clean up fakes.
    def deregister(tool_class)
      @registry.delete(tool_class)
    end

    # The tool classes whose required scope is covered by `scopes` (the token's
    # granted scopes). Presentation only -- `tools/list` is filtered by this,
    # while `tools/call` is enforced at the HTTP layer by `required_scope`.
    def for_scopes(scopes)
      granted = Array(scopes).map(&:to_s)
      @registry.select { |_tool_class, scope| granted.include?(scope) }.keys
    end

    # The scope a named tool requires, or nil for an unknown tool. Returning nil
    # for unknown tools is deliberate: the controller then declines to issue a
    # 403 step-up and lets the SDK answer with its own "unknown tool" error.
    def required_scope(tool_name)
      return nil if tool_name.blank?

      name = tool_name.to_s
      @registry.each { |tool_class, scope| return scope if tool_class.name_value == name }
      nil
    end
  end
end
