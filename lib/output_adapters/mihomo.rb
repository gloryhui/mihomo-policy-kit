# frozen_string_literal: true

module MPK
  module OutputAdapters
    class Mihomo < Base
      def id = 'mihomo'
      def extension = '.yaml'

      def render(policy)
        mapping!(policy)
        YAML.dump(policy)
      end

      def validate(content)
        document = YAML.safe_load(content, permitted_classes: [Symbol], aliases: true)
        raise Error, 'mihomo adapter produced invalid YAML' unless document.is_a?(Hash)
      rescue Psych::Exception => e
        raise Error, "mihomo adapter produced invalid YAML: #{e.message}"
      end

      def write(content, output_path)
        validate(content)
        document = YAML.safe_load(content, permitted_classes: [Symbol], aliases: true)
        BuildHelpers.write_and_test(document, output_path)
      end

      # Pre-promotion core check: run `mihomo -t` against the staged candidate
      # so a failing core test is caught before any artifact is promoted.
      def validate_core(candidate_path)
        BuildHelpers.validate_mihomo_core(candidate_path)
      end
    end
  end
end
