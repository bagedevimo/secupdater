require "open3"
require "json"
require "bundler"

module Secupdater
  class Ecosystem
    class Rubygems < Secupdater::Ecosystem
      FROZEN_EXIT_CODE = 16

      def self.ecosystem_name = "RubyGems"

      def manifest_paths = ["Gemfile.lock"]

      def snapshot
        Bundler::LockfileParser.new(Bundler.read_file("Gemfile.lock"))
          .specs
          .to_h { [it.name, DependencySpec.new(it.name, it.platform.to_s, it.version)] }
      end

      def diff_snapshot(a, b)
        (a.keys | b.keys).filter_map do |gem|
          next if a[gem] == b[gem]

          spec = a[gem] || b[gem]

          DependencySpecDiff.new(
            spec,
            a[gem]&.version,
            b[gem]&.version,
          )
        end
      end

      def run_update(names, level)
        output, status = Open3.capture2e(bundle_env, "bundle", "lock", "--update", *Array(names), "--conservative", "--#{level}", "--strict")

        if status.exitstatus == FROZEN_EXIT_CODE
          raise Secupdater::Error, "bundle lock can't change Gemfile.lock (is BUNDLE_DEPLOYMENT set?)\n#{output}"
        end

        unless status.success?
          raise Secupdater::UpdateCommandFailed.new(
            "bundle lock command returned #{status.exitstatus}",
            status.exitstatus,
            output
          )
        end
      end

      def parse_advisories(io)
        raw_report = JSON.parse(io.read)

        raw_report["results"].filter_map do |result|
          next unless result["type"] == "unpatched_gem"

          advisory = result["advisory"]

          advisory_id = ["cve", "osvdb", "ghsa"].filter_map do
            if advisory[it]
              "#{it}/#{advisory[it]}"
            end
          end.join("-")
          advisory_id = advisory["id"] if advisory_id.empty?

          SecurityAdvisory.new(result["gem"]["name"], advisory_id, advisory["patched_versions"])
        end
      end

      def satisfies_requirement?(version, requirement)
        req = Gem::Requirement.create(requirement.split(/,\s*/))
        ver = Gem::Version.create(version)
        req.satisfied_by?(ver)
      end

      private

      # When secupdater itself runs under `bundle exec` (e.g. an image whose
      # entrypoint is `bundle exec`), undo what that set up so bundle lock works on
      # the Gemfile and Gemfile.lock here. PATH is left alone, as callers may have
      # changed it since.
      def bundle_env
        original = Bundler.original_env
        rubyopt = original["RUBYOPT"]&.gsub(%r{-r\S*bundler/setup\S*}, "")&.strip

        (Bundler::EnvironmentPreserver::BUNDLER_KEYS - %w[PATH MANPATH]).to_h { [it, original[it]] }.merge(
          "BUNDLE_FROZEN" => "false",
          "BUNDLE_GEMFILE" => File.expand_path("Gemfile"),
          "BUNDLE_LOCKFILE" => nil,
          "RUBYOPT" => rubyopt.nil? || rubyopt.empty? ? nil : rubyopt
        )
      end
    end
  end
end
