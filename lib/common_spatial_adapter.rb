# Written to be compatible with ActiveRecord 2.1.0.

#Addition of a flag indicating if the index is spatial
ActiveRecord::ConnectionAdapters::IndexDefinition.class_eval do
  attr_accessor :spatial

  def initialize(table, name, unique, spatial,columns)
    super(table,name,unique,columns)
    @spatial = spatial
  end
  
end

# Modified from active_record/schema_dumper.rb.  This is fragile, since changes to the original
# SchemaDumper#table and #indexes will not be reflected in the overridden method.  However, AR
# currently gives us no choice.  For reference in upgrading this method to match AR's implementation,
# modifications for SpatialAdapter are marked with [SA].
ActiveRecord::SchemaDumper.class_eval do
  def table(table, stream)
    columns = @connection.columns(table)
    begin
      tbl = StringIO.new

      if @connection.respond_to?(:pk_and_sequence_for)
        pk, pk_seq = @connection.pk_and_sequence_for(table)
      end
      pk ||= 'id'

      tbl.print "  create_table #{table.inspect}"
      if columns.detect { |c| c.name == pk }
        if pk != 'id'
          tbl.print %Q(, :primary_key => "#{pk}")
        end
      else
        tbl.print ", :id => false"
      end
      tbl.print ", :force => true"
      tbl.puts " do |t|"

      column_specs = columns.map do |column|
        raise StandardError, "Unknown type '#{column.sql_type}' for column '#{column.name}'" if @types[column.type].nil?
        next if column.name == pk
        spec = {}
        spec[:name]      = column.name.inspect
        spec[:type]      = column.type.to_s
        spec[:limit]     = column.limit.inspect if column.limit != @types[column.type][:limit] && column.type != :decimal
        spec[:precision] = column.precision.inspect if !column.precision.nil?
        spec[:scale]     = column.scale.inspect if !column.scale.nil?
        spec[:null]      = 'false' if !column.null
        spec[:default]   = default_string(column.default) if !column.default.nil?
        if column.is_a?(SpatialColumn)                                # +[SA]
          spec[:srid]   = column.srid.inspect   if column.srid != -1  # +[SA]
          spec[:with_z] = column.with_z.inspect if column.with_z      # +[SA]
          spec[:with_m] = column.with_m.inspect if column.with_m      # +[SA]
        end                                                           # +[SA]
        (spec.keys - [:name, :type]).each{ |k| spec[k].insert(0, "#{k.inspect} => ")}
        spec
      end.compact

      # find all migration keys used in this table
      # keys = [:name, :limit, :precision, :scale, :default, :null] & column_specs.map(&:keys).flatten                          # -[SA]
      keys = [:name, :limit, :precision, :scale, :default, :null, :srid, :with_z, :with_m] & column_specs.map(&:keys).flatten   # +[SA]

      # figure out the lengths for each column based on above keys
      lengths = keys.map{ |key| column_specs.map{ |spec| spec[key] ? spec[key].length + 2 : 0 }.max }

      # the string we're going to sprintf our values against, with standardized column widths
      format_string = lengths.map{ |len| "%-#{len}s" }

      # find the max length for the 'type' column, which is special
      type_length = column_specs.map{ |column| column[:type].length }.max

      # add column type definition to our format string
      format_string.unshift "    t.%-#{type_length}s "

      format_string *= ''

      column_specs.each do |colspec|
        values = keys.zip(lengths).map{ |key, len| colspec.key?(key) ? colspec[key] + ", " : " " * len }
        values.unshift colspec[:type]
        tbl.print((format_string % values).gsub(/,\s*$/, ''))
        tbl.puts
      end

      tbl.puts "  end"
      tbl.puts
    
      indexes(table, tbl)

      tbl.rewind
      stream.print tbl.read
    rescue => e
      stream.puts "# Could not dump table #{table.inspect} because of following #{e.class}"
      stream.puts "#   #{e.message}"
      stream.puts
    end
  
    stream
  end
  
  def indexes(table, stream)
    indexes = @connection.indexes(table)
    indexes.each do |index|
      stream.print "  add_index #{index.table.inspect}, #{index.columns.inspect}, :name => #{index.name.inspect}"
      stream.print ", :unique => true" if index.unique
      stream.print ", :spatial=> true " if index.spatial   # +[SA]
      stream.puts
    end
    
    stream.puts unless indexes.empty?
  end
end




module SpatialAdapter
  #Translation of geometric data types
  def geometry_data_types
    {
      :point => { :name => "POINT" },
      :line_string => { :name => "LINESTRING" },
      :polygon => { :name => "POLYGON" },
      :geometry_collection => { :name => "GEOMETRYCOLLECTION" },
      :multi_point => { :name => "MULTIPOINT" },
      :multi_line_string => { :name => "MULTILINESTRING" },
      :multi_polygon => { :name => "MULTIPOLYGON" },
      :geometry => { :name => "GEOMETRY"}
    }
  end
  
end


#using a mixin instead of subclassing Column since each adapter can have a specific subclass of Column
module SpatialColumn
  attr_reader  :geometry_type, :srid, :with_z, :with_m
    
  def initialize(name, default, sql_type = nil, null = true,srid=-1,with_z=false,with_m=false)
    super(name,default,sql_type,null)
    @geometry_type = geometry_simplified_type(@sql_type)
    @srid = srid
    @with_z = with_z
    @with_m = with_m
  end

  
  #Redefines type_cast to add support for geometries
  def type_cast(value)
    return nil if value.nil?
    case type
    when :geometry then self.class.string_to_geometry(value)
    else super
    end
  end
    
  #Redefines type_cast_code to add support for geometries. 
  #
  #WARNING : Since ActiveRecord keeps only the string values directly returned from the database, it translates from these to the correct types everytime an attribute is read (using the code returned by this method), which is probably ok for simple types, but might be less than efficient for geometries. Also you cannot modify the geometry object returned directly or your change will not be saved. 
  def type_cast_code(var_name)
    case type
    when :geometry then "#{self.class.name}.string_to_geometry(#{var_name})"
    else super
    end
  end

  
  #Redefines klass to add support for geometries
  def klass
    case type
    when :geometry then GeoRuby::SimpleFeatures::Geometry
    else super
    end
  end
  
  private
  
  #Redefines the simplified_type method to add behabiour for when a column is of type geometry
  def simplified_type(field_type)
    case field_type
    when /geometry|point|linestring|polygon|multipoint|multilinestring|multipolygon|geometrycollection/i then :geometry
    else super
    end
  end

  #less simlpified geometric type to be use in migrations
  def geometry_simplified_type(field_type)
    case field_type
    when /^point$/i then :point
    when /^linestring$/i then :line_string
    when /^polygon$/i then :polygon
    when /^geometry$/i then :geometry
    when /multipoint/i then :multi_point
    when /multilinestring/i then :multi_line_string
    when /multipolygon/i then :multi_polygon
    when /geometrycollection/i then :geometry_collection
    end
  end


end
