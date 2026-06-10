import { Controller } from "@hotwired/stimulus"

// Switches between the preview and source panels, replaying the
// panel-reveal transition on the panel that becomes active.
//
// The t-panel-slide class is applied only while the reveal runs: its
// transform would otherwise turn the panel into the containing block for
// the fullscreen overlay's position: fixed.
export default class extends Controller {
  static targets = ["tab", "panel"]

  disconnect() {
    clearTimeout(this.revealTimer)
  }

  select({ params: { panel } }) {
    this.tabTargets.forEach(tab => {
      tab.setAttribute("aria-selected", tab.dataset.tabsPanelParam === panel)
    })
    this.panelTargets.forEach(candidate => {
      if (candidate.dataset.panel === panel) {
        this.reveal(candidate)
      } else {
        candidate.hidden = true
        this.cleanUp(candidate)
      }
    })
  }

  reveal(panel) {
    if (!panel.hidden) return

    panel.hidden = false
    panel.classList.add("t-panel-slide")
    void panel.offsetWidth
    panel.dataset.open = "true"

    clearTimeout(this.revealTimer)
    this.revealTimer = setTimeout(() => this.cleanUp(panel), this.openMs + 20)
  }

  cleanUp(panel) {
    panel.classList.remove("t-panel-slide")
    delete panel.dataset.open
  }

  get openMs() {
    const value = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--panel-open-dur"))
    return Number.isFinite(value) ? value : 400
  }
}
