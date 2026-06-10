class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Gates only the app's own UI: paste content (live/raw/show) must open in
  # any browser -- that's the product's whole promise.
  allow_browser versions: :modern, only: %i[ new create ]
end
