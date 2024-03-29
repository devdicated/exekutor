# frozen_string_literal: true

require_relative "lib/exekutor/version"

Gem::Specification.new do |spec|
  spec.name = "exekutor"
  spec.version = Exekutor::VERSION
  spec.authors = ["Roy"]
  spec.email = ["roy@devdicated.com"]

  spec.summary = "ActiveJob adapter with PostgreSQL backend."
  spec.description = <<~DESC
    PostgreSQL backed active job adapter which uses `LISTEN/NOTIFY` to listen for jobs and `FOR UPDATE SKIP LOCKED` to
    reserve jobs.
  DESC
  spec.homepage = "https://github.com/devdicated/exekutor"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.cert_chain = ["certs/devdicated.pem"]
  if $PROGRAM_NAME.end_with?("gem") && ARGV == ["build", __FILE__]
    spec.signing_key = File.expand_path("~/.ssh/gem-private_key.pem")
  end

  spec.files = Dir[
    "app/**/*",
    "lib/**/*",
    "LICENSE.txt",
  ]
  spec.require_paths = ["lib"]

  spec.bindir = "exe"
  spec.executables = %w[exekutor]

  spec.add_dependency "activejob", ">= 6.0", "< 8.0"
  spec.add_dependency "activerecord", ">= 6.0", "< 8.0"
  spec.add_dependency "railties", ">= 6.0", "< 8.0"

  spec.add_dependency "concurrent-ruby", "~> 1.1"
  spec.add_dependency "gli", "~> 2.0"
  spec.add_dependency "rainbow", "~> 3.0"
  spec.add_dependency "terminal-table", "~> 3.0"

  spec.add_development_dependency "combustion", "~> 1.3"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "minitest-reporters", "~> 1.6"
  spec.add_development_dependency "mocha", "~> 2.0"
  spec.add_development_dependency "pg", "~> 1.4"
  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "rubocop", "~> 1.21"
  spec.add_development_dependency "rubocop-minitest", "~> 0.29"
  spec.add_development_dependency "rubocop-performance", "~> 1.16"
  spec.add_development_dependency "rubocop-rails", "~> 2.18"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "timecop", "~> 0.9"
  spec.add_development_dependency "webrick", "~> 1.6"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.add_development_dependency "yard-activesupport-concern", "~> 0.0"
end
