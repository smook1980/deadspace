# frozen_string_literal: true

module DeadCode
  # Defaults target a conventional Rails 7 app. Override any key with a YAML file
  # (`--config path`, or `.dead_code.yml` in the app root). List values replace the
  # defaults unless the key is prefixed with `extra_` (e.g. `extra_ignore_methods`), which appends.
  class Config
    DEFAULTS = {
      # Definitions are indexed from these; their code also counts as references.
      "source_globs" => %w[app/**/*.rb lib/**/*.rb lib/**/*.rake config/**/*.rb],
      # Ruby that only references code (top-level, always live). Their defs are not reported.
      "reference_globs" => %w[db/seeds.rb db/seeds/**/*.rb script/**/*.rb Rakefile config.ru],
      # View-ish files: identifiers are tokenized (not parsed) and count as references.
      "template_globs" => %w[app/**/*.erb app/**/*.haml app/**/*.slim app/**/*.mjml app/**/*.liquid
                             lib/**/*.erb lib/**/*.haml lib/**/*.slim],
      # Ruby-syntax templates parsed with Prism.
      "ruby_template_globs" => %w[app/**/*.jbuilder app/**/*.rabl app/**/*.builder app/**/*.axlsx
                                  app/**/*.prawn app/**/*.ruby],
      # Only snake_case identifiers (API payload keys like `floor_plan_delete`) are taken from these.
      "js_globs" => %w[app/javascript/**/*.js app/javascript/**/*.jsx app/javascript/**/*.ts
                       app/javascript/**/*.tsx app/assets/**/*.js app/assets/**/*.coffee],
      # Only CamelCase constant names are taken from these (Sidekiq cron, observers, etc).
      "constant_text_globs" => %w[config/**/*.yml config/**/*.yaml config/**/*.json],
      # References from here are reported as "referenced in tests" but never keep code alive.
      "test_globs" => %w[spec/**/*.rb test/**/*.rb],
      "exclude_globs" => %w[vendor/** node_modules/** tmp/** log/** public/** coverage/**
                            db/migrate/** config/locales/** **/node_modules/**],
      "routes_globs" => %w[config/routes.rb config/routes/**/*.rb],
      # Class/module bodies defined in these files are entry points (run at boot).
      "root_globs" => %w[config/**/*.rb],
      # Constants that are always live. Exact names or /regex/ strings.
      "ignore_constants" => [],
      # Methods treated as invoked by Ruby/Rails/gems. Exact names or /regex/ strings.
      "ignore_methods" => %w[
        initialize perform call method_missing respond_to_missing? respond_to? inherited included
        extended prepended method_added singleton_method_added const_missing to_s to_str to_h to_hash
        to_a to_ary to_i to_int to_f to_r to_sym to_proc to_param to_json as_json to_xml to_yaml
        serializable_hash to_partial_path to_model to_key to_liquid to_csv model_name inspect
        pretty_print hash eql? each each_pair coerce initialize_copy initialize_dup initialize_clone
        marshal_dump marshal_load _dump _load encode_with init_with read_attribute_for_serialization
        read_attribute_for_validation attributes validate_each validate resolve up down change
        default_url_options url_options cache_key cache_key_with_version cache_version
        table_name primary_key inheritance_column sti_name policy_class human_attribute_name
        search_data should_index? search_import searchkick_index subscribed unsubscribed connect
        disconnect receive delivering_email delivered_email deliver! perform_now serialize
        deserialize serialize? render_in before_render table_name_prefix table_name_suffix
        on_complete on_success on_death rolledback! committed! before_committed! info_for_paper_trail
        user_for_paper_trail pundit_user append_info_to_payload
        /\A(before|after|around)_(validation|save|create|update|destroy|commit|rollback|initialize|find|touch)\z/
        /\Aransack(able|ortable)_/
        /\A[^a-z_]/
      ],
      # Superclasses whose subclasses are only reached by explicit reference (not discovered by
      # a library). Subclasses of any other external class are reported as "likely unused".
      "known_base_classes" => %w[
        Object BasicObject StandardError Exception RuntimeError ArgumentError TypeError NameError
        NotImplementedError Struct SimpleDelegator Delegator Hash Array String
        ActiveRecord::Base ActionController::Base ActionController::API ActionMailer::Base
        ActiveJob::Base ActiveModel::Validator ActiveModel::EachValidator
      ],
      # Ignore "never referenced, but its method names are called elsewhere" overlap for method
      # names called from more than this many live scopes (e.g. `name`, `id`, `value`).
      "overlap_scope_threshold" => 15
    }.freeze

    attr_reader :values

    def self.load(root, path)
      values = DEFAULTS.dup
      path ||= File.join(root, ".dead_code.yml")
      if File.exist?(path)
        overrides = YAML.safe_load_file(path) || {}
        overrides.each do |key, value|
          if key.start_with?("extra_")
            base = key.delete_prefix("extra_")
            raise ArgumentError, "Unknown config key #{key} in #{path}" unless DEFAULTS.key?(base)

            values[base] = Array(values[base]) + Array(value)
          else
            raise ArgumentError, "Unknown config key #{key} in #{path}" unless DEFAULTS.key?(key)

            values[key] = value
          end
        end
      end
      new(values)
    end

    def initialize(values)
      @values = values
      @ignore_methods = Matcher.new(values["ignore_methods"])
      @ignore_constants = Matcher.new(values["ignore_constants"])
    end

    def [](key) = @values.fetch(key)
    def ignored_method?(name) = @ignore_methods.match?(name)
    def ignored_constant?(fqn) = @ignore_constants.match?(fqn)

    # Exact strings or "/regex/" strings.
    class Matcher
      def initialize(patterns)
        @exact = Set.new
        @regexes = []
        Array(patterns).each do |p|
          p = p.to_s
          if p.length > 2 && p.start_with?("/") && p.end_with?("/")
            @regexes << Regexp.new(p[1..-2])
          else
            @exact << p
          end
        end
      end

      def match?(value) = @exact.include?(value) || @regexes.any? { |r| r.match?(value) }
    end
  end
end
