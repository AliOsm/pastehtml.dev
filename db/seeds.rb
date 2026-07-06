# Seeds the project's own vanity blog pages. Each lives at <slug>.pastehtml.dev
# (the slugs are reserved so nobody else can claim them) and, once seeded, also
# as an ordinary paste at /p/<slug> and /p/<slug>/raw|render|markdown.
# Idempotent: safe to run in any environment, any number of times.
Paste::LEGACY_VANITY_SUBDOMAINS.each do |slug|
  next if Paste.where("LOWER(custom_subdomain) = ?", slug).exists?

  file = Rails.root.join("db/seeds/vanity/#{slug}.html")
  next unless file.exist?

  # One transaction so a paste never persists without its grandfathered subdomain.
  Paste.transaction do
    paste = Paste.create!(content: file.read, original_filename: "#{slug}.html")
    # The model blocks users from claiming reserved subdomains; these pages ARE
    # the legitimate owners of their reserved slugs, so set the subdomain
    # directly, past that self-check.
    paste.update_column(:custom_subdomain, slug)
    puts "Seeded vanity page #{slug} -> /p/#{slug} (token #{paste.token})"
  end
end
