class Tag < ApplicationRecord
  has_many :post_tags, dependent: :destroy
  has_many :posts, through: :post_tags

  # What a tag name is, in one place. It was written four times — here, in
  # Post#sync_tags, in ApplicationHelper and in TagsController — and only this
  # copy also stripped whitespace, so "#Ruby " reached three of them as three
  # different strings (finding 9 of the 2026-08-18 review).
  def self.normalize(name)
    name.to_s.strip.downcase
  end

  normalizes :name, with: ->(n) { normalize(n) }

  validates :name, presence: true, uniqueness: true
end
