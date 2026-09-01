class User < ApplicationRecord
  MINIMUM_PASSWORD_LENGTH = 8
  # What a username is, defined once and used twice. It was two regexes that
  # disagreed on case and on length — the model's and the route's — with
  # nothing saying whether the disagreement was intended (finding 9 of the
  # 2026-08-18 review). It is intended, and now it is derived:
  #
  # The model decides what may be *stored*: lowercase, because usernames are
  # normalised on write, and bounded in length.
  #
  # The route decides what may be *typed*, and is deliberately looser on both
  # counts. It matches any case so that /@ADA reaches the controller, which
  # downcases before looking up — a stricter route would 404 on a handle
  # someone capitalised, which is worse than finding it. It is unanchored
  # because Rails route constraints must be, and unbounded in length because a
  # too-long name is a miss, not a routing error.
  USERNAME_CHARACTERS = "a-z0-9_".freeze
  USERNAME_LENGTH = 3..20
  USERNAME_FORMAT = /\A[#{USERNAME_CHARACTERS}]{#{USERNAME_LENGTH.min},#{USERNAME_LENGTH.max}}\z/
  USERNAME_ROUTE_CONSTRAINT = /[#{USERNAME_CHARACTERS}]+/i
  MAX_DISPLAY_NAME_LENGTH = 50
  MAX_BIO_LENGTH = 160

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_one_attached :avatar

  # Not dependent: :destroy. Posts outlive the account that wrote them — see
  # ADR 0005 — so destroying a user with posts is refused rather than quietly
  # taking the posts with it. The foreign key refuses it at the database level
  # too; this makes the refusal an error you can read.
  has_many :posts, dependent: :restrict_with_error
  has_many :likes, dependent: :destroy
  has_many :reposts, dependent: :destroy

  # Addresses are stored already lower-cased, so the unique index on the column
  # enforces case-insensitive uniqueness on its own (F-2.2). The alternative — a
  # functional index over LOWER(email_address) — is written differently on SQLite
  # and PostgreSQL, which N-1.2 rules out. The username works the same way:
  # normalised on write, one plain unique index, nothing adapter-specific.
  # Already folded on both sides — the query by downcase, the column by the
  # normalisation above — so this one survives the adapter switch. It gains only
  # the ESCAPE clause, for the same reason Post.search does: usernames may
  # contain underscores, and without it searching "a_b" matched "axb" too.
  scope :search, ->(query) {
    where("username LIKE ? ESCAPE '\\'", "%#{sanitize_sql_like(query.downcase)}%")
  }

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :username, with: ->(u) { u.strip.downcase }

  validates :email_address, presence: true,
                            format: { with: URI::MailTo::EMAIL_REGEXP },
                            uniqueness: true

  validates :username, presence: true,
                       uniqueness: true,
                       format: { with: USERNAME_FORMAT,
                                 message: "must be 3–20 characters: letters, numbers and underscores only" }

  # allow_nil so a user can be updated without resupplying a password.
  # has_secure_password already requires one to be present on create.
  validates :password, length: { minimum: MINIMUM_PASSWORD_LENGTH }, allow_nil: true

  validates :display_name, length: { maximum: MAX_DISPLAY_NAME_LENGTH }
  validates :bio, length: { maximum: MAX_BIO_LENGTH }
  validate :avatar_content_type_allowed

  AVATAR_THUMBNAIL_SIZE = [ 48, 48 ].freeze
  AVATAR_DISPLAY_SIZE = [ 128, 128 ].freeze

  # What the UI shows on the author line: the display name when one is set,
  # falling back to the username. This retires milestone 3's stopgap of showing
  # the email local part.
  def name
    display_name.presence || username
  end

  def avatar_thumbnail
    ImagePolicy.variant(avatar, resize_to_fill: AVATAR_THUMBNAIL_SIZE)
  end

  def avatar_display
    ImagePolicy.variant(avatar, resize_to_fill: AVATAR_DISPLAY_SIZE)
  end

  private

  def avatar_content_type_allowed
    return unless avatar.attached?
    unless ImagePolicy::CONTENT_TYPES.include?(avatar.blob.content_type)
      errors.add(:avatar, "must be a PNG, JPEG, WebP or GIF image")
    end
  end
end
