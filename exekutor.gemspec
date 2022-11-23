# frozen_string_literal: true

require_relative "lib/exekutor/version"

Gem::Specification.new do |spec|
  spec.name = "exekutor"
  spec.version = Exekutor::VERSION
  spec.authors = ["Roy"]
  spec.email = ["roy.vanenk@leeo.eu"]

  spec.summary = "ActiveJob adapter with PostgreSQL backend."
  # spec.description = "TODO: Write a longer description or delete this line."
  # spec.homepage = "TODO: Put your gem's website or public repo URL here."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  # spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  # spec.metadata["homepage_uri"] = spec.homepage
  # spec.metadata["source_code_uri"] = "TODO: Put your gem's public repo URL here."
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

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
  spec.add_dependency "concurrent-ruby", "~> 1.1"
  spec.add_dependency "rainbow", ">= 3.0"
  spec.add_dependency "thor", ">= 1.0"
end
