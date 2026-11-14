# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class RouteParserTest < Minitest::Test
  def routes(source)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\n#{source}\nend\n")
      table = Deadspace::RouteParser.new(dir, ["config/routes.rb"]).parse
      [table.actions.transform_values { |s| s.to_a.sort }, table]
    end
  end

  def test_resources_with_only_except_and_singular_resource
    actions, = routes(<<~RUBY)
      resources :posts, only: %i[index show]
      resources :tags, except: [:destroy, :edit, :new]
      resource :profile, only: :show
    RUBY
    assert_equal({ "posts" => %w[index show], "tags" => %w[create index show update], "profiles" => %w[show] }, actions)
  end

  def test_nested_member_collection_and_namespace
    actions, = routes(<<~RUBY)
      namespace :admin do
        resources :users, only: [] do
          member { post :ban }
          collection do
            get "search"
          end
          get :preview
          resources :notes, only: :index
          post :approve, on: :member
        end
      end
    RUBY
    assert_equal %w[approve ban preview search], actions["admin/users"]
    assert_equal %w[index], actions["admin/notes"]
  end

  def test_explicit_targets_scopes_and_shorthand
    actions, = routes(<<~RUBY)
      get "login", controller: "sessions", action: :new
      post "/mfa", controller: :sessions, action: :mfa
      match "/legacy/*path", to: "legacy#show", via: :get
      get "reports/weekly"
      get "/old" => "pages#old"
      get "/deals", to: redirect("/deals/deals")
      root to: "home#index"
      scope "scim/v2", module: "scim/v2" do
        resources :groups, only: :index
      end
      scope path: "x/:id", module: nil do
        resources :things, controller: "contacts/things", only: :index
      end
      controller :pages do
        get "about"
      end
      resources :companies, controller: :companies_people, only: :index
      get "abs", controller: "/top/level", action: :go
    RUBY
    assert_equal %w[mfa new], actions["sessions"]
    assert_equal %w[show], actions["legacy"]
    assert_equal %w[weekly], actions["reports"]
    assert_equal %w[about old], actions["pages"]
    assert_equal %w[index], actions["home"]
    assert_equal %w[index], actions["scim/v2/groups"]
    assert_equal %w[index], actions["contacts/things"]
    assert_equal %w[index], actions["companies_people"]
    assert_equal %w[go], actions["top/level"]
    refute actions.key?("deals")
  end

  def test_concerns_devise_controllers_and_dynamic_segments
    actions, table = routes(<<~RUBY)
      concern :commentable do
        resources :comments, only: :create
      end
      resources :articles, only: :show, concerns: :commentable
      devise_for :users, controllers: { sessions: "users/sessions" }
      get ":controller(/:action(/:id))"
    RUBY
    assert_equal %w[create], actions["comments"]
    assert_includes table.wildcard_controllers, "users/sessions"
    assert table.dynamic
  end
end
