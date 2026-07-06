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
      const active = tab.dataset.tabsPanelParam === panel
      tab.setAttribute("aria-selected", active)
      tab.tabIndex = active ? 0 : -1 // roving tabindex: only the selected tab is in the tab order
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

  // ArrowLeft/Right (direction-aware for RTL) and Home/End move selection and
  // focus between tabs, as expected of an ARIA tablist.
  navigate(event) {
    const step = { ArrowRight: 1, ArrowLeft: -1, Home: "first", End: "last" }[event.key]
    if (step === undefined) return
    event.preventDefault()

    const tabs = this.tabTargets
    const rtl = getComputedStyle(this.element).direction === "rtl"
    const current = Math.max(0, tabs.indexOf(event.target))
    let index
    if (step === "first") index = 0
    else if (step === "last") index = tabs.length - 1
    else index = (current + (rtl ? -step : step) + tabs.length) % tabs.length

    const tab = tabs[index]
    this.select({ params: { panel: tab.dataset.tabsPanelParam } })
    tab.focus()
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
