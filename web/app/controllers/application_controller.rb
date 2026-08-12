class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # A record that is not there is a page, not a crash (F-8.6.2). Posts are
  # deleted for real, so following a link to one that has gone is ordinary
  # rather than exceptional, and `public/404.html` answers it with an unstyled
  # page that carries no way back.
  #
  # This also catches authorisation, which here is scoping — `Current.user
  # .posts.find` does not find someone else's row (F-3.5) — and the page is
  # deliberately the same one. Somebody probing for other people's post ids
  # should not be able to tell "deleted" from "not yours".
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  private

  # Negotiated rather than tested against `request.format.html?`, because
  # `Accept: */*` — curl, link checkers, most bots — resolves to `Mime::ALL`,
  # for which `html?` is false. Testing it served those clients an empty 404.
  # `format.html` matches `*/*`; `format.any` catches everything else.
  def render_not_found
    respond_to do |format|
      format.html { render "errors/not_found", status: :not_found }
      format.any  { head :not_found }
    end
  end
end
