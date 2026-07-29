import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "launcher"]
  static values = { markAllReadUrl: String }

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
    const wasOpen = this.element.classList.contains("notification-open")
    this.setOpen(false)
    sessionStorage.removeItem(this.storageKey)
    if (wasOpen) this.markAllRead()
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

  markAllRead() {
    const token = document.querySelector("meta[name='csrf-token']")?.content

    fetch(this.markAllReadUrlValue, {
      method: "PATCH",
      headers: { "X-CSRF-Token": token, Accept: "application/json" },
      credentials: "same-origin"
    }).then((response) => {
      if (!response.ok) return

      this.element.querySelectorAll(".notification-drawer-item.unread").forEach((item) => {
        item.classList.remove("unread")
        item.querySelector(".notification-mark-read")?.remove()
      })
      this.element.querySelector(".notification-badge")?.remove()
    })
  }
}
