import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["answer"]

  beforeMorph(event) {
    if (event.target !== this.element || !this.hasAnswerTarget) return

    const replacement = event.detail.newElement.querySelector("textarea[name='answer_text']")
    if (replacement) replacement.value = this.answerTarget.value
  }
}
