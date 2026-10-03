# frozen_string_literal: true

require_relative 'app'

module MPK
  module Web
    module Runtime
      module_function

      def app(env = ENV)
        production = env['RACK_ENV'] == 'production'
        if production && (env['MPK_EXTERNAL_AUTH'] != 'nginx' || env['MPK_PUBLIC_BASE_URL'].to_s.empty?)
          abort 'Production requires MPK_EXTERNAL_AUTH=nginx and MPK_PUBLIC_BASE_URL; see docs/web-console.md.'
        end
        if production
          begin
            uri = URI.parse(env['MPK_PUBLIC_BASE_URL'])
            raise ArgumentError unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.query && !uri.fragment && ['', '/'].include?(uri.path)
          rescue URI::InvalidURIError, ArgumentError
            abort 'Production MPK_PUBLIC_BASE_URL must be an HTTPS origin.'
          end
        end
        root = env['MPK_DATA_ROOT'] || (production ? '/var/lib/mihomo-policy-kit' : File.join(BuildHelpers::ROOT_DIR, 'runtime'))
        db = Services::Database.open(env['MPK_DB_PATH'] || File.join(root, 'mpk.db'))
        publisher = MPK::Publisher::Publisher.new(root: env['MPK_PUBLISH_ROOT'] || root)
        control = Services::ControlPlane.new(db: db, data_root: root, crypto: Services::Crypto.new(env['MPK_MASTER_KEY']), publisher: publisher)
        Class.new(App).tap do |klass|
          klass.opts[:control_plane] = control
          klass.opts[:production] = production
          klass.opts[:public_origin] = env['MPK_PUBLIC_BASE_URL'].to_s.chomp('/')
        end
      end
    end
  end
end
