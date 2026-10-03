# frozen_string_literal: true

require 'roda'
require 'json'
require_relative '../services/control_plane'

module MPK
  module Web
    class App < Roda
      plugin :all_verbs
      plugin :error_handler do |error|
        failure = if error.is_a?(Services::Failure)
          error
        elsif error.is_a?(MPK::Error)
          Services::Failure.new('operation_failed', 'Operation failed; check Publisher state and dependencies.')
        else
          Services::Failure.new('internal_error', 'Operation failed without changing the active subscription.', 500)
        end
        response.status = failure.status
        response['content-type'] = 'application/json; charset=utf-8'
        JSON.generate(error: { code: failure.code, message: failure.message })
      end

      def service
        self.class.opts.fetch(:control_plane)
      end

      def respond(value, status = 200)
        request.halt([status, response.headers, [JSON.generate(value)]])
      end

      def body
        raise Services::Failure.new('invalid_content_type', 'Use application/json.', 415) unless request.env['CONTENT_TYPE'].to_s.split(';').first == 'application/json'
        raw = request.body.read(Services::SourceManager::MAX_BYTES + 1025)
        raise Services::Failure.new('input_too_large', 'Request body is too large.', 413) if raw.bytesize > Services::SourceManager::MAX_BYTES + 1024
        value = JSON.parse(raw)
        raise JSON::ParserError unless value.is_a?(Hash)
        value
      rescue JSON::ParserError
        raise Services::Failure.new('invalid_json', 'Expected a JSON object.', 400)
      end

      def mutate(status = 200)
        service.locked { respond(yield, status) }
      end

      def guard!
        env = request.env
        host = request.host
        public_origin = self.class.opts[:public_origin].to_s
        hosts = %w[localhost 127.0.0.1]
        hosts << URI.parse(public_origin).host unless public_origin.empty?
        raise Services::Failure.new('untrusted_host', 'Untrusted Host.', 403) unless hosts.include?(host)
        if self.class.opts[:production] && env['HTTP_X_MPK_AUTHENTICATED'].to_s.empty?
          raise Services::Failure.new('authentication_required', 'Management requires the authenticated reverse proxy.', 401)
        end
        return if %w[GET HEAD].include?(request.request_method)
        raise Services::Failure.new('csrf_rejected', 'Missing management request header.', 403) unless env['HTTP_X_MPK_REQUEST'] == '1'
        origin = env['HTTP_ORIGIN'].to_s
        origins = self.class.opts[:production] ? [public_origin] : %w[http://localhost:5173 http://127.0.0.1:5173]
        raise Services::Failure.new('csrf_rejected', 'Untrusted request origin.', 403) unless origin.empty? || origins.include?(origin)
      end

      route do |r|
        response['content-type'] = 'application/json; charset=utf-8'
        response['cache-control'] = 'no-store'
        response['x-content-type-options'] = 'nosniff'
        response['referrer-policy'] = 'no-referrer'
        guard!
        r.on 'api', 'v1' do
          r.get('health') { respond({ status: 'ok', schema_version: service.db[:schema_info].get(:version) }) }
          r.get('dashboard') { respond(service.dashboard) }
          r.on 'sources' do
            r.is do
              r.get { respond(service.sources.list) }
              r.post { params = body; mutate(201) { service.sources.save(params) } }
            end
            r.on Integer do |id|
              r.is do
                r.patch { params = body; mutate { service.sources.save(params, id: id) } }
                r.delete { mutate { service.sources.delete(id) } }
              end
              r.post('refresh') { mutate { service.sources.refresh(id) } }
            end
          end
          r.on 'nodes' do
            r.is { r.get { respond(service.nodes(r.params)) } }
            r.post('batch-selection') { params = body; mutate { service.select_nodes(params) } }
            r.on Integer do |id|
              r.patch('selection') { params = body.merge('node_ids' => [id]); mutate { service.select_nodes(params) } }
            end
          end
          r.on 'profiles' do
            r.is do
              r.get { respond(service.profiles) }
              r.post { params = body; mutate(201) { service.save_profile(params) } }
            end
            r.on Integer do |id|
              r.is do
                r.patch { params = body; mutate { service.save_profile(params, id: id) } }
                r.delete { mutate { service.delete_profile(id) } }
              end
              r.post('build') { mutate(201) { service.build(id) } }
            end
          end
          r.get('builds') { respond(service.builds) }
          r.on 'publisher' do
            r.get('status') { respond(service.publisher_status) }
            r.post('publish') { params = body; mutate { service.publish(params['build_id']) } }
            r.post('rollback') { mutate { service.rollback } }
            r.on 'tokens' do
              r.is do
                r.get { respond(service.tokens) }
                r.post { params = body; mutate(201) { service.create_token(params['name'], self.class.opts[:public_origin]) } }
              end
              r.on String do |name|
                r.delete { mutate { service.revoke_token(name) } }
              end
            end
          end
        end
        respond({ error: { code: 'not_found', message: 'API route not found.' } }, 404)
      end
    end
  end
end
