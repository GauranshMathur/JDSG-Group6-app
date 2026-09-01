# What an uploaded image may be, and what the app does to one before showing it.
#
# This was four places: `Post::IMAGE_CONTENT_TYPES`, `User::AVATAR_CONTENT_TYPES`,
# and the same list typed out again in two `accept:` attributes. Adding a format
# meant a five-place edit with no compiler help, and the transformation was
# written out wherever a variant was built — including inside a template, which
# is how a privacy rule came to live in the view layer. Finding 7 of the
# 2026-08-18 architecture review.
#
# It is a plain module rather than a concern because nothing here is per-record:
# it is the policy, and models and views both read it.
module ImagePolicy
  CONTENT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze

  # The same list in the form a file input wants.
  ACCEPT = CONTENT_TYPES.join(",").freeze

  # Applied to every variant the app renders. `strip` is the reason this is
  # policy rather than presentation: a photo from a phone carries the place it
  # was taken, and a rendered image must not.
  #
  # Note what this does *not* cover — the original blob keeps its metadata and
  # remains reachable by its own Active Storage route. F-7.4 is worded "on
  # upload" and is really "on render"; the gap is recorded in REQUIREMENTS.md
  # rather than papered over here.
  VARIANT = { format: :webp, saver: { strip: true } }.freeze

  # A variant of `attachment` resized by `resize`, carrying the policy above.
  def self.variant(attachment, **resize)
    attachment.variant(**resize, **VARIANT)
  end
end
