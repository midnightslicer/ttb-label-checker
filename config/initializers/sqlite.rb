# Tune SQLite for concurrent web + background-job access.
# WAL lets readers and the Solid Queue writer work without blocking each other.
ActiveSupport.on_load(:active_record_sqlite3adapter) do
  prepend(Module.new do
    def configure_connection
      super
      execute("PRAGMA journal_mode=WAL;")
      execute("PRAGMA synchronous=NORMAL;")
      execute("PRAGMA foreign_keys=ON;")
    end
  end)
end
