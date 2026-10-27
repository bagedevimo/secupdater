require "dry/cli"

module Secupdater
  module CLI
    def self.run
      Dry::CLI.new(Commands).call
    end
    
    module Commands
      extend Dry::CLI::Registry

      class Run < Dry::CLI::Command
        option :ecosystem, values: ["rubygems"], required: true, desc: "Ecosystem to run checks for"

        option :verbose, type: :boolean, default: false
        option :debug, type: :boolean, default: false

        argument :advisories, required: true, desc: "Advisory file generated from (for example) bundle audit --output json"

        def call(ecosystem:, advisories:, verbose:, debug:)
          log_level = if debug then :debug elsif verbose then :info else :warn end
          results = Runner.new(ecosystem: ecosystem, log_level: log_level, publisher: publisher).call(advisories)

          exit(1) if results.value?(:failed)
        rescue Secupdater::Error => e
          err.puts e.message
          exit(1)
        end

        private

        def publisher
          return unless ENV["SECUPDATER_GITLAB_TOKEN"]

          Publisher::Gitlab.new(ENV["SECUPDATER_GITLAB_TOKEN"], ENV.fetch("CI_PROJECT_ID"), ENV.fetch("CI_DEFAULT_BRANCH"))
        rescue KeyError => e
          raise Secupdater::Error, "SECUPDATER_GITLAB_TOKEN is set but #{e.key} isn't"
        end
      end

      register "run", Run
    end
  end
end
