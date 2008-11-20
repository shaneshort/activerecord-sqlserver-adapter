require 'active_record/connection_adapters/abstract_adapter'
require_library_or_gem 'dbi' unless defined?(DBI)
require 'core_ext/dbi'
require 'core_ext/active_record'
require 'base64'

module ActiveRecord
  
  class Base
    
    def self.sqlserver_connection(config) #:nodoc:
      config.symbolize_keys!
      mode        = config[:mode] ? config[:mode].to_s.upcase : 'ADO'
      username    = config[:username] ? config[:username].to_s : 'sa'
      password    = config[:password] ? config[:password].to_s : ''
      if mode == "ODBC"
        raise ArgumentError, "Missing DSN. Argument ':dsn' must be set in order for this adapter to work." unless config.has_key?(:dsn)
        dsn       = config[:dsn]
        driver_url = "DBI:ODBC:#{dsn}"
      else
        raise ArgumentError, "Missing Database. Argument ':database' must be set in order for this adapter to work." unless config.has_key?(:database)
        database  = config[:database]
        host      = config[:host] ? config[:host].to_s : 'localhost'
        driver_url = "DBI:ADO:Provider=SQLOLEDB;Data Source=#{host};Initial Catalog=#{database};User ID=#{username};Password=#{password};"
      end
      conn = DBI.connect(driver_url, username, password)
      conn["AutoCommit"] = true
      ConnectionAdapters::SQLServerAdapter.new(conn, logger, [driver_url, username, password])
    end
   
  end
  
  module ConnectionAdapters
    
    class SQLServerColumn < Column
            
      def initialize(name, default, sql_type = nil, null = true, sqlserver_options = {})
        @sqlserver_options = sqlserver_options
        super(name, default, sql_type, null)
      end
      
      class << self
        
        def string_to_binary(value)
         "0x#{value.unpack("H*")[0]}"
        end
        
        def binary_to_string(value)
          value =~ /[^[:xdigit:]]/ ? value : [value].pack('H*')
        end
        
      end
      
      def is_identity?
        @sqlserver_options[:is_identity]
      end
      
      def is_special?
        # TODO: Not sure if these should be added: varbinary(max), nchar, nvarchar(max)
        sql_type =~ /^text|ntext|image$/
      end
      
      def is_utf8?
        sql_type =~ /nvarchar|ntext|nchar|nvarchar(max)/i
      end
      
      def table_name
        @sqlserver_options[:table_name]
      end
      
      def table_klass
        @table_klass ||= table_name.classify.constantize rescue nil
        (@table_klass && @table_klass < ActiveRecord::Base) ? @table_klass : nil
      end
      
      private
      
      def extract_limit(sql_type)
        case sql_type
          when /^smallint/i   then  2
          when /^int/i        then  4
          when /^bigint/i     then  8
          else super
        end
      end
      
      def simplified_type(field_type)
        case field_type
          when /real/i              then :float
          when /money/i             then :decimal
          when /image/i             then :binary
          when /bit/i               then :boolean
          when /uniqueidentifier/i  then :string
          when /datetime/i          then simplified_datetime
          else super
        end
      end
      
      def simplified_datetime
        if table_klass && table_klass.coerced_sqlserver_date_columns.include?(name)
          :date
        elsif table_klass && table_klass.coerced_sqlserver_time_columns.include?(name)
          :time
        else
          :datetime
        end
      end
      
    end #SQLServerColumn
    
    # In ADO mode, this adapter will ONLY work on Windows systems, since it relies on 
    # Win32OLE, which, to my knowledge, is only available on Windows.
    #
    # This mode also relies on the ADO support in the DBI module. If you are using the
    # one-click installer of Ruby, then you already have DBI installed, but the ADO module 
    # is *NOT* installed. You will need to get the latest source distribution of Ruby-DBI 
    # from http://ruby-dbi.sourceforge.net/ unzip it, and copy the file from 
    # <tt>src/lib/dbd_ado/ADO.rb</tt> to <tt>X:/Ruby/lib/ruby/site_ruby/1.8/DBD/ADO/ADO.rb</tt>
    # 
    # You will more than likely need to create the ADO directory. Once you've installed 
    # that file, you are ready to go.
    # 
    # In ODBC mode, the adapter requires the ODBC support in the DBI module which requires
    # the Ruby ODBC module. Ruby ODBC 0.996 was used in development and testing,
    # and it is available at http://www.ch-werner.de/rubyodbc/
    #
    # Options:
    #
    # * <tt>:mode</tt>          -- ADO or ODBC. Defaults to ADO.
    # * <tt>:username</tt>      -- Defaults to sa.
    # * <tt>:password</tt>      -- Defaults to empty string.
    # * <tt>:windows_auth</tt>  -- Defaults to "User ID=#{username};Password=#{password}"
    #
    # ADO specific options:
    #
    # * <tt>:host</tt>          -- Defaults to localhost.
    # * <tt>:database</tt>      -- The name of the database. No default, must be provided.
    # * <tt>:windows_auth</tt>  -- Use windows authentication instead of username/password.
    #
    # ODBC specific options:
    #
    # * <tt>:dsn</tt>           -- Defaults to nothing.
    # 
    class SQLServerAdapter < AbstractAdapter
      
      ADAPTER_NAME            = 'SQLServer'.freeze
      DATABASE_VERSION_REGEXP = /Microsoft SQL Server\s+(\d{4})/
      SUPPORTED_VERSIONS      = [2000,2005].freeze
      LIMITABLE_TYPES         = [:string,:integer,:float].freeze
      
      cattr_accessor :native_text_database_type
      
      class << self
        
        def type_limitable?(type)
          LIMITABLE_TYPES.include?(type.to_sym)
        end
        
      end
      
      def initialize(connection, logger, connection_options=nil)
        super(connection, logger)
        @connection_options = connection_options
        @sqlserver_columns_cache = {}
        unless SUPPORTED_VERSIONS.include?(database_year)
          raise NotImplementedError, "Currently, only #{SUPPORTED_VERSIONS.to_sentence} are supported."
        end
      end
      
      # ABSTRACT ADAPTER =========================================#
      
      def adapter_name
        ADAPTER_NAME
      end
      
      def supports_migrations?
        true
      end
      
      def supports_ddl_transactions?
        true
      end
      
      def database_version
        @database_version ||= select_value('SELECT @@version')
      end
      
      def database_year
        DATABASE_VERSION_REGEXP.match(database_version)[1].to_i
      end
      
      def sqlserver_2000?
        database_year == 2000
      end
      
      def sqlserver_2005?
        database_year == 2005
      end
      
      def inspect
        "#<#{self.class} year: #{database_year}, connection_options: #{@connection_options.inspect}>"
      end
      
      def native_text_database_type
        self.class.native_text_database_type || (sqlserver_2005? ? 'varchar(max)' : 'text')
      end
      
      # QUOTING ==================================================#
      
      def quote(value, column = nil)
        if value.kind_of?(String) && column && column.type == :binary
          column.class.string_to_binary(value)
        else
          super
        end
      end
      
      def quote_string(string)
        string.to_s.gsub(/\'/, "''")
      end
      
      def quote_column_name(column_name)
        column_name.to_s.split('.').map{ |name| "[#{name}]" }.join('.')
      end
      
      def quote_table_name(table_name)
        return table_name if table_name =~ /^\[.*\]$/
        quote_column_name(table_name)
      end
      
      def quoted_true
        '1'
      end

      def quoted_false
        '0'
      end
      
      def quoted_date(value)
        if value.acts_like?(:time) && value.respond_to?(:usec)
          "#{super}.#{sprintf("%06d",value.usec)[0..2]}"
        else
          super
        end
      end
      
      # REFERENTIAL INTEGRITY ====================================#
      
      def disable_referential_integrity(&block)
        do_execute "EXEC sp_MSForEachTable 'ALTER TABLE ? NOCHECK CONSTRAINT ALL'"
        yield
      ensure
        do_execute "EXEC sp_MSForEachTable 'ALTER TABLE ? CHECK CONSTRAINT ALL'"
      end
      
      # CONNECTION MANAGEMENT ====================================#
      
      def active?
        raw_connection.execute("SELECT 1").finish
        true
      rescue DBI::DatabaseError, DBI::InterfaceError
        false
      end

      def reconnect!
        disconnect!
        @connection = DBI.connect(*@connection_options)
      rescue DBI::DatabaseError => e
        @logger.warn "#{adapter_name} reconnection failed: #{e.message}" if @logger
        false
      end

      def disconnect!
        raw_connection.disconnect rescue nil
      end
      
      def finish_statement_handle(handle)
        handle.finish if handle && handle.respond_to?(:finish) && !handle.finished?
        handle
      end
      
      # DATABASE STATEMENTS ======================================#
      
      def select_rows(sql, name = nil)
        raw_select(sql,name).last
      end
      
      def execute(sql, name = nil, &block)
        if table_name = query_requires_identity_insert?(sql)
          handle = with_identity_insert_enabled(table_name) { raw_execute(sql,name,&block) }
        else
          handle = raw_execute(sql,name,&block)
        end
        finish_statement_handle(handle)
      end
      
      def begin_db_transaction
        do_execute "BEGIN TRANSACTION"
      end

      def commit_db_transaction
        do_execute "COMMIT TRANSACTION"
      end

      def rollback_db_transaction
        do_execute "ROLLBACK TRANSACTION" rescue nil
      end
      
      def add_limit_offset!(sql, options)
        # Validate and/or convert integers for :limit and :offets options.
        if options[:offset]
          raise ArgumentError, "offset should have a limit" unless options[:limit]
          unless options[:offset].kind_of?(Integer)
            if options[:offset] =~ /^\d+$/
              options[:offset] = options[:offset].to_i
            else
              raise ArgumentError, "offset should be an integer"
            end
          end
        end
        if options[:limit] && !(options[:limit].kind_of?(Integer))
          if options[:limit] =~ /^\d+$/
            options[:limit] = options[:limit].to_i
          else
            raise ArgumentError, "limit should be an integer"
          end
        end
        # The business of adding limit/offset
        if options[:limit] and options[:offset]
          total_rows = select_value("SELECT count(*) as TotalRows from (#{sql.gsub(/\bSELECT(\s+DISTINCT)?\b/i, "SELECT#{$1} TOP 1000000000")}) tally").to_i
          if (options[:limit] + options[:offset]) >= total_rows
            options[:limit] = (total_rows - options[:offset] >= 0) ? (total_rows - options[:offset]) : 0
          end
          # Make sure we do not need a special limit/offset for association limiting. http://gist.github.com/25118
          add_limit_offset_for_association_limiting!(sql,options) and return if sql_for_association_limiting?(sql)
          # Wrap the SQL query in a bunch of outer SQL queries that emulate proper LIMIT,OFFSET support.
          sql.sub!(/^\s*SELECT(\s+DISTINCT)?/i, "SELECT * FROM (SELECT TOP #{options[:limit]} * FROM (SELECT#{$1} TOP #{options[:limit] + options[:offset]}")
          sql << ") AS tmp1"
          if options[:order]
            order = options[:order].split(',').map do |field|
              order_by_column, order_direction = field.split(" ")
              order_by_column = quote_column_name(order_by_column)
              # Investigate the SQL query to figure out if the order_by_column has been renamed.
              if sql =~ /#{Regexp.escape(order_by_column)} AS (t\d_r\d\d?)/
                # Fx "[foo].[bar] AS t4_r2" was found in the SQL. Use the column alias (ie 't4_r2') for the subsequent orderings
                order_by_column = $1
              elsif order_by_column =~ /\w+\.\[?(\w+)\]?/
                order_by_column = $1
              else
                # It doesn't appear that the column name has been renamed as part of the query. Use just the column
                # name rather than the full identifier for the outer queries.
                order_by_column = order_by_column.split('.').last
              end
              # Put the column name and eventual direction back together
              [order_by_column, order_direction].join(' ').strip
            end.join(', ')
            sql << " ORDER BY #{change_order_direction(order)}) AS tmp2 ORDER BY #{order}"
          else
            sql << ") AS tmp2"
          end
        elsif options[:limit] && sql !~ /^\s*SELECT (@@|COUNT\()/i
          if md = sql.match(/^(\s*SELECT)(\s+DISTINCT)?(.*)/im)
            sql.replace "#{md[1]}#{md[2]} TOP #{options[:limit]}#{md[3]}"
          else
            # Account for building SQL fragments without SELECT yet. See #update_all and #limited_update_conditions.
            sql.replace "TOP #{options[:limit]} #{sql}"
          end
        end
      end
      
      def add_lock!(sql, options)
        # http://blog.sqlauthority.com/2007/04/27/sql-server-2005-locking-hints-and-examples/
        return unless options[:lock]
        lock_type = options[:lock] == true ? 'WITH(HOLDLOCK, ROWLOCK)' : options[:lock]
        from_table = sql.match(/FROM(.*)WHERE/im)[1]
        sql.sub! from_table, "#{from_table}#{lock_type} "
      end
      
      def empty_insert_statement(table_name)
        "INSERT INTO #{quote_table_name(table_name)} DEFAULT VALUES"
      end
      
      def case_sensitive_equality_operator
        "COLLATE Latin1_General_CS_AS ="
      end
      
      def limited_update_conditions(where_sql, quoted_table_name, quoted_primary_key)
        match_data = where_sql.match(/(.*)WHERE/)
        limit = match_data[1]
        where_sql.sub!(limit,'')
        "WHERE #{quoted_primary_key} IN (SELECT #{limit} #{quoted_primary_key} FROM #{quoted_table_name} #{where_sql})"
      end
      
      # SCHEMA STATEMENTS ========================================#
      
      def native_database_types
        binary = sqlserver_2005? ? "varbinary(max)" : "image"
        {
          :primary_key => "int NOT NULL IDENTITY(1, 1) PRIMARY KEY",
          :string      => { :name => "varchar", :limit => 255  },
          :text        => { :name =>  native_text_database_type },
          :integer     => { :name => "int", :limit => 4 },
          :float       => { :name => "float", :limit => 8 },
          :decimal     => { :name => "decimal" },
          :datetime    => { :name => "datetime" },
          :timestamp   => { :name => "datetime" },
          :time        => { :name => "datetime" },
          :date        => { :name => "datetime" },
          :binary      => { :name =>  binary },
          :boolean     => { :name => "bit"}
        }
      end
      
      def table_alias_length
        128
      end
      
      def tables(name = nil)
        select_values "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_NAME <> 'dtproperties'"
      end
      
      def indexes(table_name, name = nil)
        select("EXEC sp_helpindex #{quote_table_name(table_name)}",name).inject([]) do |indexes,index|
          if index['index_description'] =~ /primary key/
            indexes
          else
            name    = index['index_name']
            unique  = index['index_description'] =~ /unique/
            columns = index['index_keys'].split(',').map do |column|
              column.strip!
              column.gsub! '(-)', '' if column.ends_with?('(-)')
              column
            end
            indexes << IndexDefinition.new(table_name, name, unique, columns)
          end
        end
      end
      
      def columns(table_name, name = nil)
        return [] if table_name.blank?
        cache_key = unqualify_table_name(table_name)
        @sqlserver_columns_cache[cache_key] ||= column_definitions(table_name).collect do |ci|
          sqlserver_options = ci.except(:name,:default_value,:type,:null)
          SQLServerColumn.new ci[:name], ci[:default_value], ci[:type], ci[:null], sqlserver_options
        end
      end
      
      def create_table(table_name, options = {})
        super
        remove_sqlserver_columns_cache_for(table_name)
      end
      
      def rename_table(table_name, new_name)
        do_execute "EXEC sp_rename '#{table_name}', '#{new_name}'"
      end
      
      def drop_table(table_name, options = {})
        super
        remove_sqlserver_columns_cache_for(table_name)
      end
      
      def add_column(table_name, column_name, type, options = {})
        super
        remove_sqlserver_columns_cache_for(table_name)
      end
      
      def remove_column(table_name, *column_names)
        column_names.flatten.each do |column_name|
          remove_check_constraints(table_name, column_name)
          remove_default_constraint(table_name, column_name)
          remove_indexes(table_name, column_name)
          do_execute "ALTER TABLE #{quote_table_name(table_name)} DROP COLUMN #{quote_column_name(column_name)}"
        end
        remove_sqlserver_columns_cache_for(table_name)
      end
      
      def change_column(table_name, column_name, type, options = {})
        sql_commands = []
        change_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
        change_column_sql << " NOT NULL" if options[:null] == false
        sql_commands << change_column_sql
        if options_include_default?(options)
          remove_default_constraint(table_name, column_name)
          sql_commands << "ALTER TABLE #{quote_table_name(table_name)} ADD CONSTRAINT #{default_name(table_name,column_name)} DEFAULT #{quote(options[:default])} FOR #{quote_column_name(column_name)}"
        end
        sql_commands.each { |c| do_execute(c) }
        remove_sqlserver_columns_cache_for(table_name)
      end
      
      def change_column_default(table_name, column_name, default)
        remove_default_constraint(table_name, column_name)
        do_execute "ALTER TABLE #{quote_table_name(table_name)} ADD CONSTRAINT #{default_name(table_name, column_name)} DEFAULT #{quote(default)} FOR #{quote_column_name(column_name)}"
        remove_sqlserver_columns_cache_for(table_name)
      end
      
      def rename_column(table_name, column_name, new_column_name)
        column_for(table_name,column_name)
        do_execute "EXEC sp_rename '#{table_name}.#{column_name}', '#{new_column_name}', 'COLUMN'"
        remove_sqlserver_columns_cache_for(table_name)
      end
      
      def remove_index(table_name, options = {})
        do_execute "DROP INDEX #{table_name}.#{quote_column_name(index_name(table_name, options))}"
      end
      
      def type_to_sql(type, limit = nil, precision = nil, scale = nil)
        limit = nil unless self.class.type_limitable?(type)
        if type.to_s == 'integer'
          case limit
            when 1..2       then  'smallint'
            when 3..4, nil  then  'integer'
            when 5..8       then  'bigint'
            else raise(ActiveRecordError, "No integer type has byte size #{limit}. Use a numeric with precision 0 instead.")
          end
        else
          super
        end
      end
      
      def add_order_by_for_association_limiting!(sql, options)
        # Disertation http://gist.github.com/24073
        # Information http://weblogs.sqlteam.com/jeffs/archive/2007/12/13/select-distinct-order-by-error.aspx
        return sql if options[:order].blank?
        columns = sql.match(/SELECT\s+DISTINCT(.*)FROM/)[1].strip
        sql.sub!(/SELECT\s+DISTINCT/,'SELECT')
        sql << "GROUP BY #{columns} ORDER BY #{order_to_min_set(options[:order])}"
      end
      
      def change_column_null(table_name, column_name, null, default = nil)
        column = column_for(table_name,column_name)
        unless null || default.nil?
          do_execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
        end
        sql = "ALTER TABLE #{table_name} ALTER COLUMN #{quote_column_name(column_name)} #{type_to_sql column.type, column.limit, column.precision, column.scale}"
        sql << " NOT NULL" unless null
        do_execute sql
      end
      
      def pk_and_sequence_for(table_name)
        idcol = identity_column(table_name)
        idcol ? [idcol.name,nil] : nil
      end
      
      # RAKE UTILITY METHODS =====================================#

      def recreate_database(name)
        existing_database = current_database.to_s
        if name.to_s == existing_database
          do_execute 'USE master' 
        end
        drop_database(name)
        create_database(name)
      ensure
        do_execute "USE #{existing_database}" if name.to_s == existing_database 
      end

      def drop_database(name)
        retry_count = 0
        max_retries = 1
        begin
          do_execute "DROP DATABASE #{name}"
        rescue ActiveRecord::StatementInvalid => err
          # Remove existing connections and rollback any transactions if we received the message
          #  'Cannot drop the database 'test' because it is currently in use'
          if err.message =~ /because it is currently in use/
            raise if retry_count >= max_retries
            retry_count += 1
            remove_database_connections_and_rollback(name)
            retry
          else
            raise
          end
        end
      end

      def create_database(name)
        do_execute "CREATE DATABASE #{name}"
      end
      
      def current_database
        select_value 'SELECT DB_NAME()'
      end

      def remove_database_connections_and_rollback(name)
        # This should disconnect all other users and rollback any transactions for SQL 2000 and 2005
        # http://sqlserver2000.databases.aspfaq.com/how-do-i-drop-a-sql-server-database.html
        do_execute "ALTER DATABASE #{name} SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
      end
      
      
      
      protected
      
      # DATABASE STATEMENTS ======================================
      
      def select(sql, name = nil, ignore_special_columns = false)
        repair_special_columns(sql) unless ignore_special_columns
        fields, rows = raw_select(sql,name)
        rows.inject([]) do |results,row|
          row_hash = {}
          fields.each_with_index do |f, i|
            row_hash[f] = row[i]
          end
          results << row_hash
        end
      end
      
      def insert_sql(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        set_utf8_values!(sql)
        super || select_value("SELECT SCOPE_IDENTITY() AS Ident")
      end
      
      def update_sql(sql, name = nil)
        set_utf8_values!(sql)
        execute(sql, name)
        select_value('SELECT @@ROWCOUNT AS AffectedRows')
      end
      
      def raw_execute(sql, name = nil, &block)
        log(sql, name) do
          if block_given?
            raw_connection.execute(sql) { |handle| yield(handle) }
          else
            raw_connection.execute(sql)
          end
        end
      end
      
      def without_type_conversion
        raw_connection.convert_types = false if raw_connection.respond_to?(:convert_types=)
        yield
      ensure
        raw_connection.convert_types = true if raw_connection.respond_to?(:convert_types=)
      end
      
      def do_execute(sql,name=nil)
        log(sql, name || 'EXECUTE') do
          raw_connection.do(sql)
        end
      end
      
      def raw_select(sql, name = nil)
        handle = raw_execute(sql,name)
        fields = handle.column_names
        results = handle_as_array(handle)
        rows = results.inject([]) do |rows,row|
          row.each_with_index do |value, i|
            # DEPRECATED in DBI 0.4.0 and above. Remove when 0.2.2 and lower is no longer supported.
            if value.is_a? DBI::Timestamp
              row[i] = value.to_sqlserver_string
            end
          end
          rows << row
        end
        return fields, rows
      end
      
      def handle_as_array(handle)
        array = handle.inject([]) do |rows,row|
          rows << row.inject([]){ |values,value| values << value }
        end
        finish_statement_handle(handle)
        array
      end
      
      def add_limit_offset_for_association_limiting!(sql, options)
        sql.replace %|
          SET NOCOUNT ON
          DECLARE @row_number TABLE (row int identity(1,1), id int)
          INSERT INTO @row_number (id)
            #{sql}
          SET NOCOUNT OFF
          SELECT id FROM (
            SELECT TOP #{options[:limit]} * FROM (
              SELECT TOP #{options[:limit] + options[:offset]} * FROM @row_number ORDER BY row
            ) AS tmp1 ORDER BY row DESC
          ) AS tmp2 ORDER BY row
        |.gsub(/[ \t\r\n]+/,' ')
      end
      
      # SCHEMA STATEMENTS ========================================#
      
      def remove_check_constraints(table_name, column_name)
        constraints = select_values("SELECT CONSTRAINT_NAME FROM INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE where TABLE_NAME = '#{quote_string(table_name)}' and COLUMN_NAME = '#{quote_string(column_name)}'")
        constraints.each do |constraint|
          do_execute "ALTER TABLE #{quote_table_name(table_name)} DROP CONSTRAINT #{quote_column_name(constraint)}"
        end
      end
      
      def remove_default_constraint(table_name, column_name)
        constraints = select_values("SELECT def.name FROM sysobjects def, syscolumns col, sysobjects tab WHERE col.cdefault = def.id AND col.name = '#{quote_string(column_name)}' AND tab.name = '#{quote_string(table_name)}' AND col.id = tab.id")
        constraints.each do |constraint|
          do_execute "ALTER TABLE #{quote_table_name(table_name)} DROP CONSTRAINT #{quote_column_name(constraint)}"
        end
      end
      
      def remove_indexes(table_name, column_name)
        indexes(table_name).select{ |index| index.columns.include?(column_name.to_s) }.each do |index|
          remove_index(table_name, {:name => index.name})
        end
      end
      
      def default_name(table_name, column_name)
        "DF_#{table_name}_#{column_name}"
      end
      
      # IDENTITY INSERTS =========================================#
      
      def with_identity_insert_enabled(table_name, &block)
        set_identity_insert(table_name, true)
        yield
      ensure
        set_identity_insert(table_name, false)
      end
      
      def set_identity_insert(table_name, enable = true)
        sql = "SET IDENTITY_INSERT #{table_name} #{enable ? 'ON' : 'OFF'}"
        do_execute(sql,'IDENTITY_INSERT')
      rescue Exception => e
        raise ActiveRecordError, "IDENTITY_INSERT could not be turned #{enable ? 'ON' : 'OFF'} for table #{table_name}"
      end
      
      def query_requires_identity_insert?(sql)
        if insert_sql?(sql)
          table_name = get_table_name(sql)
          id_column = identity_column(table_name)
          id_column && sql =~ /INSERT[^(]+\([^)]*\[#{id_column.name}\][^)]*\)/i ? table_name : false
        else
          false
        end
      end
      
      def identity_column(table_name)
        columns(table_name).detect(&:is_identity?)
      end
      
      # HELPER METHODS ===========================================#
      
      def insert_sql?(sql)
        !(sql =~ /^\s*INSERT/i).nil?
      end
      
      def unqualify_table_name(table_name)
        table_name.to_s.split('.').last.gsub(/[\[\]]/,'')
      end
      
      def unqualify_db_name(table_name)
        table_names = table_name.to_s.split('.')
        table_names.length == 3 ? table_names.first.tr('[]','') : nil
      end
      
      def get_table_name(sql)
        if sql =~ /^\s*insert\s+into\s+([^\(\s]+)\s*|^\s*update\s+([^\(\s]+)\s*/i
          $1 || $2
        elsif sql =~ /from\s+([^\(\s]+)\s*/i
          $1
        else
          nil
        end
      end
      
      def orders_and_dirs_set(order)
        orders = order.sub('ORDER BY','').split(',').map(&:strip).reject(&:blank?)
        orders_dirs = orders.map do |ord|
          dir = nil
          if match_data = ord.match(/\b(asc|desc)$/i)
            dir = match_data[1]
            ord.sub!(dir,'').strip!
            dir.upcase!
          end
          [ord,dir]
        end
      end
      
      def order_to_min_set(order)
        orders_dirs = orders_and_dirs_set(order)
        orders_dirs.map do |o,d|
          "MIN(#{o}) #{d}".strip
        end.join(', ')
      end
      
      def sql_for_association_limiting?(sql)
        if md = sql.match(/^\s*SELECT(.*)FROM.*GROUP BY.*ORDER BY.*/im)
          select_froms = md[1].split(',')
          select_froms.size == 1 && !select_froms.first.include?('*')
        end
      end
      
      def remove_sqlserver_columns_cache_for(table_name)
        cache_key = unqualify_table_name(table_name)
        @sqlserver_columns_cache[cache_key] = nil
      end
      
      def column_definitions(table_name)
        db_name = unqualify_db_name(table_name)
        table_name = unqualify_table_name(table_name)
        # COL_LENGTH returns values that do not reflect how much data can be stored in certain data types.
        # COL_LENGTH returns -1 for varchar(max), nvarchar(max), and varbinary(max)
        # COL_LENGTH returns 16 for ntext, text, image types
        sql = %{
          SELECT
          columns.COLUMN_NAME as name,
          columns.DATA_TYPE as type,
          CASE
            WHEN columns.COLUMN_DEFAULT = '(null)' OR columns.COLUMN_DEFAULT = '(NULL)' THEN NULL
            ELSE columns.COLUMN_DEFAULT
          END as default_value,
          columns.NUMERIC_SCALE as numeric_scale,
          columns.NUMERIC_PRECISION as numeric_precision,
          CASE
            WHEN columns.DATA_TYPE IN ('nvarchar') AND COL_LENGTH(columns.TABLE_NAME, columns.COLUMN_NAME) = -1 THEN 1073741823
            WHEN columns.DATA_TYPE IN ('varchar', 'varbinary') AND COL_LENGTH(columns.TABLE_NAME, columns.COLUMN_NAME) = -1 THEN 2147483647
            WHEN columns.DATA_TYPE IN ('ntext') AND COL_LENGTH(columns.TABLE_NAME, columns.COLUMN_NAME) = 16 THEN 1073741823
            WHEN columns.DATA_TYPE IN ('text', 'image') AND COL_LENGTH(columns.TABLE_NAME, columns.COLUMN_NAME) = 16 THEN 2147483647
            ELSE COL_LENGTH(columns.TABLE_NAME, columns.COLUMN_NAME) 
          END as length,
          CASE
            WHEN columns.IS_NULLABLE = 'YES' THEN 1
            ELSE NULL
          end as is_nullable,
          CASE
            WHEN COLUMNPROPERTY(OBJECT_ID(columns.TABLE_NAME), columns.COLUMN_NAME, 'IsIdentity') = 0 THEN NULL
            ELSE 1
          END as is_identity
          FROM #{db_name}INFORMATION_SCHEMA.COLUMNS columns
          WHERE columns.TABLE_NAME = '#{table_name}'
          ORDER BY columns.ordinal_position
        }.gsub(/[ \t\r\n]+/,' ')
        results = without_type_conversion { select(sql,nil,true) }
        results.collect do |ci|
          ci.symbolize_keys!
          ci[:type] = if ci[:type] =~ /numeric|decimal/i
                        "#{ci[:type]}(#{ci[:numeric_precision]},#{ci[:numeric_scale]})"
                      else
                        "#{ci[:type]}(#{ci[:length]})"
                      end
          ci[:table_name] = table_name
          ci[:default_value] = ci[:default_value].match(/\A\(+N?'?(.*?)'?\)+\Z/)[1] if ci[:default_value]
          ci[:null] = ci[:is_nullable].to_i == 1 ; ci.delete(:is_nullable)
          ci
        end
      end
      
      def column_for(table_name, column_name)
        unless column = columns(table_name).detect { |c| c.name == column_name.to_s }
          raise ActiveRecordError, "No such column: #{table_name}.#{column_name}"
        end
        column
      end
      
      
      
      def change_order_direction(order)
        order.split(",").collect {|fragment|
          case fragment
            when  /\bDESC\b/i     then fragment.gsub(/\bDESC\b/i, "ASC")
            when  /\bASC\b/i      then fragment.gsub(/\bASC\b/i, "DESC")
            else                  String.new(fragment).split(',').join(' DESC,') + ' DESC'
          end
        }.join(",")
      end

      def special_columns(table_name)
        columns(table_name).select(&:is_special?).map(&:name)
      end

      def repair_special_columns(sql)
        special_cols = special_columns(get_table_name(sql))
        for col in special_cols.to_a
          sql.gsub!(/((\.|\s|\()\[?#{col.to_s}\]?)\s?=\s?/, '\1 LIKE ')
          sql.gsub!(/ORDER BY #{col.to_s}/i, '')
        end
        sql
      end

      def utf8_columns(table_name)
        columns(table_name).select(&:is_utf8?).map(&:name)
      end
      
      def set_utf8_values!(sql)
        utf8_cols = utf8_columns(get_table_name(sql))
        if sql =~ /^\s*UPDATE/i
          utf8_cols.each do |col|
            sql.gsub!("[#{col.to_s}] = '", "[#{col.to_s}] = N'")
          end
        elsif sql =~ /^\s*INSERT(?!.*DEFAULT VALUES\s*$)/i
          # TODO This code should be simplified
          # Get columns and values, split them into arrays, and store the original_values for when we need to replace them
          columns_and_values = sql.scan(/\((.*?)\)/m).flatten
          columns = columns_and_values.first.split(',')
          values =  columns_and_values[1].split(',')
          original_values = values.dup
          # Iterate columns that should be UTF8, and append an N to the value, if the value is not NULL
          utf8_cols.each do |col|
            columns.each_with_index do |column, idx|
              values[idx] = " N#{values[idx].gsub(/^ /, '')}" if column =~ /\[#{col}\]/ and values[idx] !~ /^NULL$/
            end
          end
          # Replace (in place) the SQL
          sql.gsub!(original_values.join(','), values.join(','))
        end
      end
      
    end #class SQLServerAdapter < AbstractAdapter
    
  end #module ConnectionAdapters
  
end #module ActiveRecord

