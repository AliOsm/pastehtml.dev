module McpTools
  # Aggregate-only view analytics for a single user-owned paste. Deliberately
  # never returns anything from the raw paste_view rows beyond counts: no
  # referrer or user-agent strings, and no IPs (only an HMAC digest is stored
  # for those, and even that never leaves this tool).
  class GetPasteStats < BaseTool
    RECENT_DAYS = 30

    tool_name "get_paste_stats"
    description <<~TEXT.strip
      Aggregate view analytics for a paste owned by the authenticated user, by
      token: total views_count, a views_by_source breakdown (zero-filled across
      all sources: show, live, raw, render), and a recent_views daily timeline
      for the last #{RECENT_DAYS} days (days with zero views are omitted from
      the timeline). Aggregate-only: never returns referrers, user agents, or
      IP addresses. Read-only.
    TEXT

    input_schema(
      type: "object",
      properties: {
        token: { type: "string", description: "The paste's token." }
      },
      required: [ "token" ],
      additionalProperties: false
    )

    output_schema(
      type: "object",
      properties: {
        views_count: { type: "integer" },
        views_by_source: {
          type: "object",
          properties: {
            show: { type: "integer" },
            live: { type: "integer" },
            raw: { type: "integer" },
            render: { type: "integer" }
          },
          required: %w[ show live raw render ]
        },
        recent_views: {
          type: "array",
          description: "One entry per day with at least one view, in the last #{RECENT_DAYS} days. Zero-view days are omitted.",
          items: {
            type: "object",
            properties: {
              date: { type: "string", description: "ISO 8601 date (YYYY-MM-DD)." },
              count: { type: "integer" }
            },
            required: %w[ date count ]
          }
        }
      },
      required: %w[ views_count views_by_source recent_views ]
    )

    annotations(
      read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
    )

    class << self
      def call(token:, server_context:)
        user = user_for(server_context)

        paste = user.pastes.find_by(token: token)
        return paste_not_found(token) if paste.nil?

        ok(
          views_count: paste.views_count,
          views_by_source: views_by_source(paste),
          recent_views: recent_views(paste)
        )
      end

      private
        def paste_not_found(token)
          failure(code: "paste_not_found", message: "No paste with token #{token.inspect}.", field: "token")
        end

        def views_by_source(paste)
          counts = paste.paste_views.group(:source).count
          PasteView::SOURCES.each_with_object({}) { |source, hash| hash[source.to_sym] = counts.fetch(source, 0) }
        end

        def recent_views(paste)
          since = RECENT_DAYS.days.ago.beginning_of_day
          counts = paste.paste_views.where(created_at: since..).group("DATE(created_at)").count

          counts.map { |date, count| { date: date.to_s, count: count } }.sort_by { |entry| entry[:date] }
        end
    end
  end
end
