import { Controller } from "@hotwired/stimulus"

// Dismisses its element (a flash message) with a short fade-out.
export default class extends Controller {
  dismiss() {
    this.element.style.transition = "opacity 150ms ease-out"
    this.element.style.opacity = "0"
    this.element.addEventListener("transitionend", () => this.element.remove(), { once: true })
  }
}
