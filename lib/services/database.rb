# frozen_string_literal: true

require 'sequel'
require 'fileutils'

module MPK
  module Services
    module Database
      module_function

      def open(path)
        FileUtils.mkdir_p(File.dirname(File.expand_path(path))) unless path == ':memory:'
        db = Sequel.sqlite(path, max_connections: 1, timeout: 5000,
          after_connect: proc { |connection| connection.execute('PRAGMA foreign_keys = ON'); connection.execute('PRAGMA busy_timeout = 5000') })
        db.run('PRAGMA journal_mode = WAL')
        Sequel.extension :migration
        Sequel::Migrator.run(db, File.expand_path('../db/migrations', __dir__))
        File.chmod(0o600, path) unless path == ':memory:' || Gem.win_platform?
        db
      end
    end
  end
end
