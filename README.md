# deadspace

Static report of code in a Rails 7+ app that nothing outside of tests reaches: whole modules, classes, methods,
and controller actions without a route, plus the tests you can delete with them. Nothing is booted or eager-loaded.
Code is parsed with [Prism](https://github.com/ruby/prism) (Ruby's own parser) and routes are read by evaluating
`config/routes.rb` statically. Requires Ruby 3.1+.

## Install

The gem is installed from GitHub; it is not published to rubygems.org.

**In the app's Gemfile** (the usual way):

```ruby
group :development do
  gem "deadspace", github: "smook1980/deadspace", tag: "v0.1.0", require: false
end
```

```bash
bundle install
bundle exec deadspace
```

`require: false` keeps it out of the app's runtime. It depends only on `activesupport`, `csv` and `prism`, so it
resolves against an existing Rails bundle.

**Standalone**, without touching the app's Gemfile:

```bash
git clone https://github.com/smook1980/deadspace.git && cd deadspace
bundle install && bundle exec rake install   # builds the gem and installs it into the current Ruby
cd path/to/app && deadspace
```

Install it under the same Ruby the app uses (`.ruby-version`), or the `deadspace` executable won't be on the path there.

## Usage

```bash
deadspace                                   # terminal report for the app in the current directory
deadspace path/to/app                       # or another app
deadspace --csv tmp/deadspace.csv           # also write a CSV
deadspace --path app/models --only unused   # narrow what is reported (analysis stays app-wide)
deadspace --ignore script/one_offs --ignore 'lib/tasks/**/backfill_*.rake'
deadspace --help
```

`--ignore` (repeatable) takes a file, a directory, or a glob relative to the app root. Ignored files are left out
completely: their classes and methods aren't reported, and their calls don't keep other code alive. Ignoring one-off
scripts therefore surfaces code that only those scripts used. `db/migrate`, `vendor` and the other `exclude_globs`
in `lib/deadspace/config.rb` are always skipped. Put permanent ignores under `extra_exclude_globs` in
`.deadspace.yml`.

## How it decides

Entry points are live: top-level code (initializers, rake files, `script/`, seeds, views, YAML), routed controller
actions, helper modules, framework hooks (`perform`, `call`, `to_param`, callback method names, ...), and anything
reopened from a gem namespace (monkey patches). A live scope makes live whatever it references: method calls,
symbols (`before_save :x`, `&:x`, `permit(:x)`), constants, and identifier-like strings. This repeats until nothing
changes. Whatever was never reached is reported, so code only called by other dead code is reported as well.

- A class or module nobody references is one finding. Its methods and nested constants are not listed separately.
- References from `spec/` and `test/` never keep code alive. They show up as `referenced in tests`.
- Methods are matched by name, not by receiver type, so a common name (`name`, `call`) keeps every method with
  that name alive. The tool errs towards "used".

**UNUSED** means no static path reaches it. **LIKELY UNUSED** means no static reference exists, but a Rails or
Ruby convention could reach it at runtime. Each finding says which convention:

| Reason | Example |
| --- | --- |
| dynamic dispatch / constant lookup | `public_send("sort_by_#{field}")`, `Object.const_get("#{iso}AddressFormatter")` |
| STI subclass | `class Featured < Post`, which can be instantiated from the `type` column |
| `descendants` / `subclasses` enumerated | eager loading discovers the subclasses |
| subclass of a library class | Devise controllers, `Liquid::Drop`, `Rails::Railtie` |
| Pundit predicate with no matching action | `def frobnicate?` in a policy |
| DSL block, gem namespace, `config/` patch | `ActiveAdmin.register X do controller do def ...` |
| model attribute writer | `foo=` mass-assigned from request params |
| unrouted public controller method used as a filter | `before_action :foo` on a public method (make it private) |

## Removable tests

Each finding lists the test blocks that go away with it, indented under the finding:

```
  ● DeadService
    app/services/dead_service.rb:1
    never referenced (2 method(s))
    referenced in tests
    Remove with it:
      spec/models/post_spec.rb:5  example calls it
      spec/services/dead_service_spec.rb:1-5  entire file
```

The report wraps to the terminal width, which can be overridden with `--width N`. It is colored when stdout is a TTY,
unless `NO_COLOR` is set or `--no-color` is passed.

`--csv out.csv` also writes `out_tests.csv`, with one row per block: test file, lines, match, entire file, and the
finding it belongs to.

- **describes**: an RSpec group about the finding, such as `RSpec.describe DeadService` or `describe "#unused_method"`
  inside `RSpec.describe Post`. Minitest `class DeadServiceTest` counts too. `#` matches instance methods, `.`/`::`
  matches class methods.
- **calls**: an example (`it`/`specify`/`test`) whose own body calls the method or references the constant. Methods
  only match inside specs whose subject is the method's class or a subclass. A call that hits a spec-local helper
  (`def x`, `let(:x)`, `subject(:x)`) doesn't match.
- Nested blocks are merged into the outermost one. A file holding nothing but the block (and `require`s) is reported
  as the whole file.
- No tests are listed for a public controller method that is still used as a filter or helper.

A "calls" example can also cover live code, so read it before deleting.

## Routes

The default parser covers `namespace`, `scope`, `controller`, `resources`/`resource` (only/except/controller/module/
concerns/member/collection/nesting), verb helpers (`to:`, `controller:`/`action:`, `"path" => "c#a"`, path shorthand),
`root`, `concern(s)`, `draw`, and `devise_for`/`use_doorkeeper` `controllers`. If the app boots, the route table is
exact:

```bash
bin/rails runner 'File.write("tmp/routes.json", Rails.application.routes.routes.map { |r|
  r.defaults.slice(:controller, :action).merge(path: r.path.spec.to_s) }.to_json)'
deadspace --routes-json tmp/routes.json
```

## Tuning

Put overrides in `.deadspace.yml` at the app root, or pass `--config path`. Keys are listed in
`lib/deadspace/config.rb`. A plain key replaces the default list. An `extra_` key appends to it:

```yaml
extra_ignore_methods: [liquid_method_missing, "/\\Awebhook_/"]   # exact names or /regex/
extra_ignore_constants: [LegacyApi]
extra_reference_globs: [lib/generators/**/*.rb]
```

## Known blind spots

- `send(variable)` with a non-literal argument can call any method. Those calls are not modeled.
- Constants or method names that only exist in the database or in external configuration, such as polymorphic `*_type`
  values, Liquid templates stored in the DB, or job names in a remote scheduler.
- Engines mounted from gems, and routes added by gems beyond `devise_for` and `use_doorkeeper`. Use `--routes-json`
  if this matters.

## Development

```bash
bundle install
bundle exec rake          # tests and RuboCop
bundle exec exe/deadspace test/fixtures/app
```

`test/fixtures/app` is a small fake Rails app with known dead and live code; the tests assert on its report.

## License

MIT. See [LICENSE](LICENSE).
