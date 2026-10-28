module Secupdater
  class Update
    attr_reader :logger, :ecosystem, :publisher, :original

    def initialize(logger, ecosystem, publisher: nil)
      @logger = logger
      @ecosystem = ecosystem
      @publisher = publisher
    end

    def call(advisories)
      @original = ecosystem.snapshot

      deps_needing_checking = advisories.group_by { it.name }

      missing = deps_needing_checking.keys - original.keys
      raise Secupdater::Error, "Advisories for dependencies not in the lockfile: #{missing.join(', ')}" if missing.any?

      deps_needing_checking.to_h do |name, dep_advisories|
        [name, update_dependency(original[name], dep_advisories)]
      end
    end

    def update_dependency(dep, advisories)
      logger.info("starting update for #{dep.name}, #{advisories.length} advisories")

      status = message = nil

      levels = ecosystem.update_levels

      levels.each do |level|
        status, message = attempt_update(dep, advisories, level)
        return status unless message

        logger.debug "#{level} update: #{message}" unless level == levels.last
      end

      if status == :failed
        logger.error message
      else
        logger.warn message
      end

      status
    rescue Secupdater::PublishFailed => e
      logger.error "#{dep.name}: #{e.message}"
      :failed
    end

    private

    def attempt_update(dep, advisories, level)
      file_changes = ecosystem.try_update(dep.name, level:)
      bump = ecosystem.diff_snapshot(original, ecosystem.snapshot).detect { it.dependency.name == dep.name }

      return [:unchanged, "#{dep.name} didn't update (stuck at #{dep.version})"] unless bump

      resolved = advisories.all? do |advisory|
        advisory.patched_versions.any? { ecosystem.satisfies_requirement?(bump.to, it) }
      end

      unless resolved
        return [:unresolved, "#{dep.name} didn't update to a version that resolves the security warnings (went from #{bump.from} to #{bump.to})"]
      end

      advisories.each do |advisory|
        logger.info "upgrading #{dep.name} from #{bump.from} to #{bump.to} (#{level}) would resolve #{advisory}"
      end

      return [:resolved, nil] unless publisher

      publisher.call(ecosystem, bump, advisories, file_changes)
      [:published, nil]
    rescue Secupdater::UpdateCommandFailed => e
      [:failed, "#{dep.name}: #{e.message}\n#{e.output}"]
    ensure
      restore(file_changes)
    end

    def restore(file_changes)
      file_changes&.each do |change|
        if change.original_content
          File.write(change.filename, change.original_content)
        else
          File.delete(change.filename)
        end
      end
    end
  end
end
