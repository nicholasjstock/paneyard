import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    key: String
  }

  connect() {
    if (!this.hasKeyValue) return

    const savedState = window.sessionStorage.getItem(this.storageKey)
    if (savedState === null) return

    this.element.open = savedState === "true"
  }

  persist() {
    if (!this.hasKeyValue) return

    window.sessionStorage.setItem(this.storageKey, this.element.open ? "true" : "false")
  }

  beforeMorph(event) {
    if (event.target !== this.element) return

    event.detail.newElement.open = this.element.open
  }

  get storageKey() {
    return `accordion:${this.keyValue}`
  }
}
