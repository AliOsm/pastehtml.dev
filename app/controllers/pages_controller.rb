# The project's own marketing/guide pages. Each renders inside the shared app
# layout (header, nav, footer) -- unlike pastes, which are served raw on their
# own isolated origins. The interactive guides (lock_it_up, mark_it_down) ship
# client-side tools in their views.
class PagesController < ApplicationController
  allow_unauthenticated_access
  allow_browser versions: :modern

  def making_of
  end

  def lock_it_up
  end

  def mark_it_down
  end
end
