import { Controller } from "@hotwired/stimulus"

// Keeps the new-run form's model dropdown in step with its agent dropdown:
// each agent offers only the models its own CLI lists (Orchestrator::ModelCatalog),
// so switching agent swaps the whole list and falls back to that agent's default.
export default class extends Controller {
  static targets = ["agent", "model"]
  static values = { catalog: Object, defaults: Object }

  agentChanged() {
    const agent = this.agentTarget.value
    const select = this.modelTarget
    select.replaceChildren(this.option("", `Default (${this.defaultsValue[agent] || "CLI default"})`))
    for (const { id, label } of this.catalogValue[agent] || []) {
      select.append(this.option(id, label))
    }
    select.value = ""
  }

  option(value, text) {
    const option = document.createElement("option")
    option.value = value
    option.textContent = text
    return option
  }
}
