import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "launcher"]

  connect() {
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

    event.detail.newElement.classList.toggle("notification-open", this.element.classList.contains("notification-open"))
  }

  setOpen(open) {
    this.element.classList.toggle("notification-open", open)
    this.panelTarget.setAttribute("aria-hidden", open ? "false" : "true")
    if (this.hasLauncherTarget) this.launcherTarget.setAttribute("aria-expanded", open ? "true" : "false")
    if (open) {
      window.setTimeout(() => this.panelTarget.focus({ preventScroll: true }), 200)
    }
  }

  get storageKey() {
    return `notifications:${window.location.pathname}`
  }
}
