import { Controller } from "@hotwired/stimulus"

// Collapses the sidebar to an icon rail and remembers the choice (F-4.8).
//
// The collapsed class lives on <html>, not on the sidebar, for two reasons:
// an inline script in <head> can apply it before first paint so the rail does
// not flash open on load, and Turbo replaces <body> on every visit but leaves
// <html> alone, so the choice survives navigation without being re-applied.
const KEY = "sidebar-collapsed"

export default class SidebarController extends Controller {
  static targets = ["toggle"]

  connect() {
    this.render()
  }

  toggle() {
    const collapsed = !this.collapsed
    try {
      window.localStorage.setItem(KEY, collapsed ? "1" : "0")
    } catch (error) {
      // Private browsing and blocked storage both throw here. The toggle still
      // works for this page; it just will not be remembered.
    }
    this.render()
  }

  get collapsed() {
    return document.documentElement.classList.contains("sidebar-is-collapsed")
  }

  render() {
    let stored = null
    try {
      stored = window.localStorage.getItem(KEY)
    } catch (error) {
      stored = null
    }

    const collapsed = stored === "1"
    document.documentElement.classList.toggle("sidebar-is-collapsed", collapsed)

    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", collapsed ? "false" : "true")
      this.toggleTarget.querySelector(".sidebar__toggle-label").textContent =
        collapsed ? "Expand the sidebar" : "Collapse the sidebar"
    }
  }
}
