# frozen_string_literal: true

# Ruby's own top-level constants, captured before libraries are loaded.
DEADSPACE_CORE_CONSTANTS = Object.constants.map(&:to_s).freeze

require "csv"
require "json"
require "set"
require "yaml"
require "prism"
require "active_support"
require "active_support/core_ext/string/inflections"

require_relative "deadspace/model"
require_relative "deadspace/config"
require_relative "deadspace/ruby_visitor"
require_relative "deadspace/test_map"
require_relative "deadspace/collector"
require_relative "deadspace/routes"
require_relative "deadspace/analyzer"
require_relative "deadspace/report"

module Deadspace
  CORE_CONSTANTS = DEADSPACE_CORE_CONSTANTS.to_set.freeze
  # Namespaces Rails ships under gem names that don't match (actionpack => ActionController, ...).
  RAILS_NAMESPACES = %w[ActionCable ActionController ActionDispatch ActionMailbox ActionMailer ActionText
                        ActionView ActiveJob ActiveModel ActiveRecord ActiveStorage ActiveSupport Arel Rails
                        Rack].freeze

  module_function

  # "Admin::User_Profiles" => "admin::userprofiles": compares names across inflection rules
  # (API vs Api) without loading the app's inflections.
  def normalize(name) = name.to_s.downcase.delete("_")

  def core_constant?(name) = CORE_CONSTANTS.include?(name) && name != "Deadspace"

  # Top-level constants owned by gems (from Gemfile.lock). Code reopening them is a monkey patch:
  # always loaded, and its methods may be called by the gem.
  def gem_namespaces(root)
    lockfile = File.join(root, "Gemfile.lock")
    names = File.exist?(lockfile) ? File.read(lockfile).scan(/^    ([\w.-]+) \(/).flatten : []
    # kt-paperclip => Paperclip, devise-two-factor => Devise
    variants = names.flat_map { |n| [n.delete("-"), n.split("-").first, n.split("-").last] }
    (variants.map { |n| normalize(n) } + RAILS_NAMESPACES.map { |n| normalize(n) }).to_set
  end

  def analyze(root, config:, routes:, ignore: [])
    index = Collector.new(root, config, ignore:).collect
    analyzer = Analyzer.new(index, routes, config, gem_namespaces: gem_namespaces(root))
    [analyzer.run, index]
  end
end
