import { Controller } from "@hotwired/stimulus"

export default class ComposerPreviewController extends Controller {
  static targets = ["container"]

  preview(event) {
    this.containerTarget.innerHTML = ""
    const files = event.target.files
    if (!files.length) return

    Array.from(files).forEach(file => {
      const reader = new FileReader()
      reader.onload = (e) => {
        const img = document.createElement("img")
        img.src = e.target.result
        img.className = "composer__preview-img"
        this.containerTarget.appendChild(img)
      }
      reader.readAsDataURL(file)
    })
  }
}
