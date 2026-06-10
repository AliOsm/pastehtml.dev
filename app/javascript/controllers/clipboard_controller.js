import { Controller } from "@hotwired/stimulus"

// Copies the share link and confirms by cross-fading the button's
// icon-and-label pair to its "Copied!" state.
export default class extends Controller {
  static targets = ["source", "swap"]

  disconnect() {
    clearTimeout(this.resetTimer)
  }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.value)
    } catch {
      this.select()
      return
    }

    this.swapTarget.dataset.state = "b"

    clearTimeout(this.resetTimer)
    this.resetTimer = setTimeout(() => (this.swapTarget.dataset.state = "a"), 2000)
  }

  select() {
    this.sourceTarget.select()
  }
}
