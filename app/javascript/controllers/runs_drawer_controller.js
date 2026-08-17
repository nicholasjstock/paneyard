import { Controller } from "@hotwired/stimulus"

// Mirrors notification_drawer_controller.js for the topbar current-runs
// launcher + slide-out panel (see "Improve the global notifications drawer").
// Open/closed state persists in sessionStorage per pathname so a Turbo
// Stream refresh or a full navigation back to the same page don't lose it.
export default class extends Controller {
  static targets = ["panel", "launcher"]

  connect() {
    if (!this.hasPanelTarget) return
    this.setOpen(sessionStorage.getItem(this.storageKey) === "open")
  }

  open(event) {
    event.preventDefault()
    event.currentTarget.blur()
    this.setOpen(true)
    sessionStorage.setItem(this.storageKey, "open")
  }

  close() {
    this.setOpen(false)
    sessionStorage.removeItem(this.storageKey)
  }

  beforeMorph(event) {
    if (event.target !== this.element) return

    event.detail.newElement.classList.toggle("runs-open", this.element.classList.contains("runs-open"))
  }

  setOpen(open) {
    this.element.classList.toggle("runs-open", open)
    if (this.hasPanelTarget) this.panelTarget.setAttribute("aria-hidden", open ? "false" : "true")
    if (this.hasLauncherTarget) this.launcherTarget.setAttribute("aria-expanded", open ? "true" : "false")
    if (open) {
      window.setTimeout(() => this.panelTarget?.focus({ preventScroll: true }), 200)
    }
  }

  get storageKey() {
    return `runs:${window.location.pathname}`
  }
}
