import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["output"]

  connect() {
    this.following = true
    this.boundRender = this.followLatest.bind(this)
    this.boundScroll = this.updateFollowing.bind(this)
    this.outputTarget.addEventListener("scroll", this.boundScroll)
    document.addEventListener("turbo:render", this.boundRender)
    this.followLatest()
  }

  disconnect() {
    this.outputTarget.removeEventListener("scroll", this.boundScroll)
    document.removeEventListener("turbo:render", this.boundRender)
  }

  updateFollowing() {
    const remaining = this.outputTarget.scrollHeight - this.outputTarget.scrollTop - this.outputTarget.clientHeight
    this.following = remaining < 24
  }

  followLatest() {
    if (!this.following) return

    requestAnimationFrame(() => {
      this.outputTarget.scrollTop = this.outputTarget.scrollHeight
    })
  }
}
