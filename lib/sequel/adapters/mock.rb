# frozen-string-literal: true

require_relative 'utils/unmodified_identifiers'

module Sequel
  module Mock
    class Connection
      # Sequel::Mock::Database object that created this connection
      attr_reader :db

      # Shard this connection operates on, when using Sequel's
      # sharding support (always :default for databases not using
      # sharding).
      attr_reader :server

      # The specific database options for this connection.
      attr_reader :opts

      # Store the db, server, and opts.
      def initialize(db, server, opts)
        @db = db
        @server = server
        @opts = opts
      end

      # Delegate to the db's #_execute method.
      def execute(sql)
        @db.send(:_execute, self, sql, :log=>false) 
      end
    end

    class Database < Sequel::Database
      set_adapter_scheme :mock

      # Set the autogenerated primary key integer
      # to be returned when running an insert query.
      # Argument types supported:
      #
      # nil :: Return nil for all inserts
      # Integer :: Starting integer for next insert, with
      #            futher inserts getting an incremented
      #            value
      # Array :: First insert gets the first value in the
      #          array, second gets the second value, etc.
      # Proc :: Called with the insert SQL query, uses
      #         the value returned
      # Class :: Should be an Exception subclass, will create a new
      #          instance an raise it wrapped in a DatabaseError.
      def autoid=(v)
        @autoid = case v
        when Integer
          i = v - 1
          proc{@mutex.synchronize{i+=1}}
        else
          v
        end
      end

      # Set the columns to set in the dataset when the dataset fetches
      # rows.  Argument types supported:
      # nil :: Set no columns
      # Array of Symbols :: Used for all datasets
      # Array (otherwise) :: First retrieval gets the first value in the
      #                      array, second gets the second value, etc.
      # Proc :: Called with the select SQL query, uses the value
      #         returned, which should be an array of symbols
      attr_writer :columns

      # Set the hashes to yield by execute when retrieving rows.
      # Argument types supported:
      #
      # nil :: Yield no rows
      # Hash :: Always yield a single row with this hash
      # Array of Hashes :: Yield separately for each hash in this array
      # Array (otherwise) :: First retrieval gets the first value
      #                      in the array, second gets the second value, etc.
      # Proc :: Called with the select SQL query, uses
      #         the value returned, which should be a hash or
      #         array of hashes.
      # Class :: Should be an Exception subclass, will create a new
      #          instance an raise it wrapped in a DatabaseError.
      attr_writer :fetch

      # Set the number of rows to return from update or delete.
      # Argument types supported:
      #
      # nil :: Return 0 for all updates and deletes
      # Integer :: Used for all updates and deletes
      # Array :: First update/delete gets the first value in the
      #          array, second gets the second value, etc.
      # Proc :: Called with the update/delete SQL query, uses
      #         the value returned.
      # Class :: Should be an Exception subclass, will create a new
      #          instance an raise it wrapped in a DatabaseError.
      attr_writer :numrows

      # Mock the server version, useful when using the shared adapters
      attr_accessor :server_version

      # Return a related Connection option connecting to the given shard.
      def connect(server)
        Connection.new(self, server, server_opts(server))
      end

      def disconnect_connection(c)
      end

      # Store the sql used for later retrieval with #sqls, and return
      # the appropriate value using either the #autoid, #fetch, or
      # #numrows methods.
      def execute(sql, opts=OPTS, &block)
        synchronize(opts[:server]){|c| _execute(c, sql, opts, &block)} 
      end
      alias execute_ddl execute

      # Store the sql used, and return the value of the #numrows method.
      def execute_dui(sql, opts=OPTS)
        execute(sql, opts.merge(:meth=>:numrows))
      end

      # Store the sql used, and return the value of the #autoid method.
      def execute_insert(sql, opts=OPTS)
        execute(sql, opts.merge(:meth=>:autoid))
      end

      # Return all stored SQL queries, and clear the cache
      # of SQL queries.
      def sqls
        @mutex.synchronize do
          s = @sqls.dup
          @sqls.clear
          s
        end
      end

      # Enable use of savepoints.
      def supports_savepoints?
        shared_adapter? ? super : true
      end

      private

      def _execute(c, sql, opts=OPTS, &block)
        sql += " -- args: #{opts[:arguments].inspect}" if opts[:arguments]
        sql += " -- #{@opts[:append]}" if @opts[:append]
        sql += " -- #{c.server.is_a?(Symbol) ? c.server : c.server.inspect}" if c.server != :default
        log_connection_yield(sql, c){} unless opts[:log] == false
        @mutex.synchronize{@sqls << sql}

        ds = opts[:dataset]
        begin
          if block
            columns(ds, sql) if ds
            _fetch(sql, (ds._fetch if ds) || @fetch, &block)
          elsif meth = opts[:meth]
            if meth == :numrows
              _numrows(sql, (ds.numrows if ds) || @numrows)
            else
              if ds
                @mutex.synchronize do
                  v = ds.autoid
                  if v.is_a?(Integer)
                    ds.send(:cache_set, :_autoid, v + 1)
                  end
                  v
                end
              end || _nextres(@autoid, sql, nil)
            end
          end
        rescue => e
          raise_error(e)
        end
      end

      def _fetch(sql, f, &block)
        case f
        when Hash
          yield f.dup
        when Array
          if f.all?{|h| h.is_a?(Hash)}
            f.each{|h| yield h.dup}
          else
            _fetch(sql, @mutex.synchronize{f.shift}, &block)
          end
        when Proc
          h = f.call(sql)
          if h.is_a?(Hash)
            yield h.dup
          elsif h
            h.each{|h1| yield h1.dup}
          end
        when Class
          if f < Exception
            raise f
          else
            raise Error, "Invalid @fetch attribute: #{v.inspect}"
          end
        when nil
          # nothing
        else
          raise Error, "Invalid @fetch attribute: #{f.inspect}"
        end
      end

      def _nextres(v, sql, default)
        case v
        when Integer
          v
        when Array
          v.empty? ? default : _nextres(@mutex.synchronize{v.shift}, sql, default)
        when Proc
          v.call(sql)
        when Class
          if v < Exception
            raise v
          else
            raise Error, "Invalid @autoid/@numrows attribute: #{v.inspect}"
          end
        when nil
          default
        else
          raise Error, "Invalid @autoid/@numrows attribute: #{v.inspect}"
        end
      end

      def _numrows(sql, v)
        _nextres(v, sql, 0)
      end

      # Additional options supported:
      #
      # :autoid :: Call #autoid= with the value
      # :columns :: Call #columns= with the value
      # :fetch ::  Call #fetch= with the value
      # :numrows :: Call #numrows= with the value
      # :extend :: A module the object is extended with.
      # :sqls :: The array to store the SQL queries in.
      def adapter_initialize
        opts = @opts
        @mutex = Mutex.new
        @sqls = opts[:sqls] || []
        @shared_adapter = false

        case db_type = opts[:host] 
        when String, Symbol
          db_type = db_type.to_sym
          unless mod = Sequel.synchronize{SHARED_ADAPTER_MAP[db_type]}
            begin
              require "sequel/adapters/shared/#{db_type}"
            rescue LoadError
            else
              mod = Sequel.synchronize{SHARED_ADAPTER_MAP[db_type]}
            end
          end

          if mod
            @shared_adapter = true
            extend(mod::DatabaseMethods)
            extend_datasets(mod::DatasetMethods)
            if defined?(mod.mock_adapter_setup)
              mod.mock_adapter_setup(self)
            end
          end
        end

        unless @shared_adapter
          extend UnmodifiedIdentifiers::DatabaseMethods
          extend_datasets UnmodifiedIdentifiers::DatasetMethods
        end

        self.autoid = opts[:autoid]
        self.columns = opts[:columns]
        self.fetch = opts[:fetch]
        self.numrows = opts[:numrows]
        extend(opts[:extend]) if opts[:extend]
        sqls
      end

      def columns(ds, sql, cs=@columns)
        case cs
        when Array
          unless cs.empty?
            if cs.all?{|c| c.is_a?(Symbol)}
              ds.columns(*cs)
            else
              columns(ds, sql, @mutex.synchronize{cs.shift})
            end
          end
        when Proc
          ds.columns(*cs.call(sql))
        when nil
          # nothing
        else
          raise Error, "Invalid @columns attribute: #{cs.inspect}"
        end
      end

      def dataset_class_default
        Dataset
      end

      def quote_identifiers_default
        shared_adapter? ? super : false
      end

      def shared_adapter?
        @shared_adapter
      end
    end

    class Dataset < Sequel::Dataset
      # The autoid setting for this dataset, if it has been overridden
      def autoid
        cache_get(:_autoid) || @opts[:autoid]
      end

      # The fetch setting for this dataset, if it has been overridden
      def _fetch
        cache_get(:_fetch) || @opts[:fetch]
      end

      # The numrows setting for this dataset, if it has been overridden
      def numrows
        cache_get(:_numrows) || @opts[:numrows]
      end

      # If arguments are provided, use them to set the columns
      # for this dataset and return self.  Otherwise, use the
      # default Sequel behavior and return the columns.
      def columns(*cs)
        if cs.empty?
          super
        else
          self.columns = cs
          self
        end
      end

      def fetch_rows(sql, &block)
        execute(sql, &block)
      end

      def quote_identifiers?
        @opts.fetch(:quote_identifiers, db.send(:quote_identifiers_default))
      end

      # Return cloned dataset with the autoid setting modified
      def with_autoid(autoid)
        clone(:autoid=>autoid)
      end

      # Return cloned dataset with the fetch setting modified
      def with_fetch(fetch)
        clone(:fetch=>fetch)
      end

      # Return cloned dataset with the numrows setting modified
      def with_numrows(numrows)
        clone(:numrows=>numrows)
      end

      private

      def execute(sql, opts=OPTS, &block)
        super(sql, opts.merge(:dataset=>self), &block)
      end

      def execute_dui(sql, opts=OPTS, &block)
        super(sql, opts.merge(:dataset=>self), &block)
      end

      def execute_insert(sql, opts=OPTS, &block)
        super(sql, opts.merge(:dataset=>self), &block)
      end

      def non_sql_option?(key)
        super || key == :fetch || key == :numrows || key == :autoid
      end
    end
  end
end
