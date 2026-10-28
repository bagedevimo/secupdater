# frozen_string_literal: true

require "dry/logger"

require_relative "secupdater/version"
require_relative "secupdater/cli"
require_relative "secupdater/ecosystem"
require_relative "secupdater/runner"
require_relative "secupdater/update"
require_relative "secupdater/publisher"
require_relative "secupdater/publisher/gitlab"

module Secupdater
  SecurityAdvisory = Struct.new(:name, :report_id, :patched_versions) do
    def to_s
      "#{name} #{report_id}"
    end
  end

  DependencySpec = Struct.new(:name, :meta, :version)
  DependencySpecDiff = Struct.new(:dependency, :from, :to)
  FileChange = Struct.new(:filename, :type, :content, :original_content)

  class Error < StandardError; end

  class UpdateCommandFailed < Error
    attr_reader :output, :exit_code

    def initialize(message = nil, exit_code = nil, output = nil)
      super(message)
      @exit_code = exit_code
      @output = output
    end
  end

  # An update command failure that trying another update level won't fix
  class UnretryableUpdateFailed < UpdateCommandFailed; end

  class PublishFailed < Error; end

  def self.build_logger(log_level: :warn)
    Dry.Logger(
      :secupdater,
      stream: $stderr,
      template: "[%<severity>s] %<message>s",
      level: log_level
    )
  end
end
