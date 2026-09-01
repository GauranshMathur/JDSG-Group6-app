import { Controller } from "@hotwired/stimulus"

export default class SubmitOnEnterController extends Controller {
  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.element.closest("form").requestSubmit()
    }
  }
}
