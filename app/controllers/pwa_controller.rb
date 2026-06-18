# Serves the installable-app manifest. Browsers fetch the manifest without our
# cookie, so the page hands its locale in the link's href (?locale=ar); we honor
# it here, otherwise the resolved request locale stands.
class PwaController < ApplicationController
  def manifest
    requested = params[:locale]
    I18n.locale = requested if I18n.available_locales.map(&:to_s).include?(requested)
  end
end
