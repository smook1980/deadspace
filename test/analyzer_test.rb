# frozen_string_literal: true

require_relative "test_helper"

class AnalyzerTest < Minitest::Test
  ROOT = File.expand_path("fixtures/app", __dir__)

  def setup
    @findings = self.class.findings
  end

  def self.findings
    @findings ||= begin
      config = DeadCode::Config.load(ROOT, nil)
      routes = DeadCode::RouteParser.new(ROOT, DeadCode::Collector.new(ROOT, config).files("routes_globs")).parse
      DeadCode.analyze(ROOT, config:, routes:).first
    end
  end

  def finding(name) = @findings.find { |f| f.name == name }

  def assert_finding(name, confidence, kind = nil)
    f = finding(name)
    assert f, "expected a finding for #{name}; got #{@findings.map(&:name).sort.inspect}"
    assert_equal confidence, f.confidence, "#{name}: #{f.reason}"
    assert_equal kind, f.kind if kind
    f
  end

  def refute_finding(name)
    f = finding(name)
    refute f, "did not expect #{name} (#{f&.confidence}: #{f&.reason})"
  end

  def test_unused_and_used_methods
    assert_finding "Post#unused_method", :unused, :method
    refute_finding "Post#title_for_display"   # &:title_for_display
    refute_finding "Post#normalize_title"     # before_save :normalize_title
    refute_finding "Post#summary="            # Post.new(summary: ...) mass assignment
    refute_finding "Post#to_param"            # framework hook
    refute_finding "Post.published"           # scope called by name
    assert_finding "Post.never_used_scope", :unused, :method
  end

  def test_methods_only_reached_from_dead_code_or_tests_are_unused
    assert_match(/only called from other unused code/, assert_finding("Post#legacy_helper", :unused).reason)
    assert assert_finding("Post#only_tested", :unused).referenced_in_tests
  end

  def test_unreferenced_class_rolls_up_its_methods
    f = assert_finding("DeadService", :unused, :class)
    assert f.referenced_in_tests
    refute_finding "DeadService#call"
    refute_finding "DeadService#helper"
  end

  def test_unreferenced_module_rolls_up_nested_classes_and_methods
    assert_finding "Legacy", :unused, :module
    refute_finding "Legacy::Importer"
    refute_finding "Legacy::Importer#run"
    refute_finding "Legacy.version"
  end

  def test_value_constant_reference_keeps_its_namespace_alive
    refute_finding "StatusHolder::Kinds"
    refute_finding "StatusHolder"
  end

  def test_controller_actions_without_routes
    assert_finding "PostsController#archive", :unused, :controller_action
    refute_finding "PostsController#index"
    refute_finding "PostsController#publish" # member route
    refute_finding "Admin::ReportsController#index"
    assert_finding "OrphansController", :unused, :class # no route reaches it at all
  end

  def test_public_filter_method_is_flagged_for_review_and_private_ones_judged_normally
    assert_match(/filter/,
                 assert_finding("ApplicationController#authenticate", :likely_unused, :controller_action).reason)
    assert_finding "ApplicationController#current_user", :unused, :method
  end

  def test_dynamic_rails_conventions_are_likely_unused_not_unused
    assert_match(/dynamic dispatch/, assert_finding("Post#sort_by_score", :likely_unused).reason)
    assert_match(/dynamic constant lookup/, assert_finding("CsvExporter", :likely_unused).reason)
    assert_match(/STI/, assert_finding("FeaturedPost", :likely_unused, :class).reason)
    refute_finding "SponsoredPost"
  end

  def test_rails_entry_points
    refute_finding "PostsHelper#post_badge" # called from a view
    assert_finding "PostsHelper#unused_badge", :unused
    refute_finding "PostPolicy"             # inferred from Post by Pundit
    refute_finding "PostPolicy#show?"       # authorize in a routed :show action
    assert_match(/Pundit/, assert_finding("PostPolicy#frobnicate?", :likely_unused).reason)
  end

  def test_boot_files_are_entry_points
    refute_finding "Sample"
  end

  def test_monkey_patches_on_gem_namespaces
    refute_finding "Paperclip::Validator"
    assert_match(/library namespace/, assert_finding("Paperclip::Validator#patched_check", :likely_unused).reason)
  end
end
