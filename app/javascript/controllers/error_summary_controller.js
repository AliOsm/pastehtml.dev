import { Controller } from "@hotwired/stimulus"

// Moves focus to a validation-error summary when it renders after a failed
// submit re-renders the page, so screen-reader and keyboard users are told the
// submit failed instead of silently landing back at the top of the page. The
// summary carries role="alert" and tabindex="-1".
export default class extends Controller {
  connect() {
    this.element.focus()
  }
}
