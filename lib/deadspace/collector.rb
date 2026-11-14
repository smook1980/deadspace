# frozen_string_literal: true

module Deadspace
  # Finds files per the config and feeds them to the Prism visitor or the text tokenizer.
  class Collector
    TEMPLATE_TOKEN_RE = /(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*|[a-z_]\w*[?!]?/
    CONSTANT_TOKEN_RE = /\b[A-Z][a-z]\w*(?:::[A-Z]\w*)*/
    SNAKE_CASE_RE = /\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/

    GLOB_CHARS = /[*?\[{]/

    # ignore: paths relative to the app root that are skipped entirely (neither definitions nor
    # references). A directory or file path ("db/migrate", "script/one_offs/x.rb") or a glob
    # ("script/**/bsd_*.rb").
    def initialize(root, config, ignore: [])
      @root = root
      @config = config
      @ignore = ignore.map { |p| p.to_s.delete_prefix("./").delete_suffix("/") }.reject(&:empty?)
    end

    def ignored?(rel)
      @ignore.any? do |pattern|
        if pattern.match?(GLOB_CHARS)
          File.fnmatch?(pattern, rel, File::FNM_PATHNAME | File::FNM_EXTGLOB)
        else
          rel == pattern || rel.start_with?("#{pattern}/")
        end
      end
    end

    def collect
      index = Index.new
      routes = Set.new(files("routes_globs"))
      seen = Set.new

      files("source_globs").each do |path|
        next unless seen.add?(path)

        # Routes DSL symbols are route names, not method calls.
        is_routes = routes.include?(path)
        # config/ gets its own top-level scope: `authentication_method = :foo` names controller methods.
        parse_ruby(index, path, :source, collect_symbols: !is_routes, collect_strings: !is_routes,
                                         top_scope: path.start_with?("config/") ? "config" : "root")
        index.stats[:ruby_files] += 1
      end
      (files("reference_globs") + files("ruby_template_globs")).each do |path|
        next unless seen.add?(path)

        parse_ruby(index, path, :reference)
        index.stats[:reference_files] += 1
      end
      files("template_globs").each do |path|
        next unless seen.add?(path)

        tokenize_template(index.scope("root"), read(path))
        index.stats[:templates] += 1
      end
      files("constant_text_globs").each do |path|
        next unless seen.add?(path)

        read(path).scan(CONSTANT_TOKEN_RE) { |c| index.scope("root").const_strings << c }
        index.stats[:config_text_files] += 1
      end
      files("js_globs").each do |path|
        next unless seen.add?(path)

        read(path).scan(SNAKE_CASE_RE) { |name| index.scope("root").names << name << "#{name}=" }
        index.stats[:js_files] += 1
      end
      files("test_globs").each do |path|
        parse_ruby(index, path, :test)
        index.stats[:test_files] += 1
      end

      index.apply_visibility_overrides!
      index
    end

    def files(key)
      excludes = @config["exclude_globs"]
      @config[key].flat_map { |g| Dir.glob(g, base: @root) }.uniq.sort.reject do |rel|
        excludes.any? { |e| File.fnmatch?(e, rel, File::FNM_EXTGLOB) } ||
          ignored?(rel) ||
          !File.file?(File.join(@root, rel))
      end
    end

    private

    def read(rel) = File.read(File.join(@root, rel), encoding: "UTF-8").scrub

    def parse_ruby(index, rel, mode, **opts)
      source = read(rel)
      result = Prism.parse(source, filepath: rel)
      if result.errors.any? && mode == :source
        index.warnings << "#{rel}: #{result.errors.size} parse error(s); analyzed the recoverable AST"
      end
      result.value.accept(RubyVisitor.new(index, rel, mode:, **opts))
      return unless mode == :test

      test_map = TestMapVisitor.new(rel, source.lines.size)
      result.value.accept(test_map)
      index.test_blocks.concat(test_map.roots)
    end

    # Templates are not parsed; every identifier is treated as a possible call/symbol and every
    # CamelCase token as a constant reference. Crude, but only errs towards "used".
    def tokenize_template(refs, text)
      text.scan(TEMPLATE_TOKEN_RE) do |token|
        if token.match?(/\A(?:::)?[A-Z]/)
          refs.const_strings << token.delete_prefix("::")
        else
          refs.names << token
          refs.symbols << token
        end
      end
    end
  end
end
