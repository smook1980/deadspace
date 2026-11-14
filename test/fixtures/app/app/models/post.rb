class Post < ApplicationRecord
  STATUSES = %w[draft live].freeze
  before_save :normalize_title
  scope :published, -> { where(published: true) }
  scope :never_used_scope, -> { where(x: 1) }

  def title_for_display = title.titleize
  def unused_method = legacy_helper
  def only_tested = 1
  def summary=(value); end
  def sort_by_score; end
  def to_param = id.to_s

  private

  def normalize_title = nil
  def legacy_helper = 2
end
