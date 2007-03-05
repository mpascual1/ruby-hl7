# $Id$
# {{{ Copyright Notice
# Copyright (c) 2006-2007 Mark Guzman
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
# }}} Copyright Notice

# {{{ ri info
#= ruby-hl7.rb
#
# Ruby HL7 is designed to provide a simple, easy to use library for
# parsing and generating HL7 (2.x) messages.
#
#== Example
# }}} ri info

require 'rubygems'
require "stringio"
require "date"
require 'facets/core/class/cattr'

module HL7
end

class HL7::Exception < StandardError
end

class HL7::ParseError < HL7::Exception
end

class HL7::RangeError < HL7::Exception
end

class HL7::Message
  include Enumerable # we treat an hl7 2.x message as a collection of segments
  attr :element_delim
  attr :item_delim
  attr :segment_delim

  def initialize( raw_msg=nil )
    @segments = []
    @segments_by_name = {}
    @item_delim = "^"
    @element_delim = '|' 
    @segment_delim = "\r"

    parse( raw_msg ) if raw_msg
  end

  def []( index )
    ret = nil

    if index.kind_of?(Range) || index.kind_of?(Fixnum)
      ret = @segments[ index ]
    elsif (index.respond_to? :to_sym)
      ret = @segments_by_name[ index.to_sym ]
      ret = ret.first if ret.length == 1
    end

    ret
  end

  def []=( index, value )
    if index.kind_of?(Range) || index.kind_of?(Fixnum)
      @segments[ index ] = value
    else
      (@segments_by_name[ index.to_sym ] ||= []) << value
    end
  end

  def <<( value )
    (@segments ||= []) << value
    name = value.class.to_s.gsub("HL7::Message::Segment::", "").to_sym
    (@segments_by_name[ name ] ||= []) << value
    sequence_segments # let's auto-set the set-id as we go
  end

  def self.parse( inobj )
    ret = HL7::Message.new
    ret.parse( inobj )
    ret
  end

  def parse( inobj )
    unless inobj.kind_of?(String) || inobj.respond_to?(:each)
      raise HL7::ParseError.new
    end

    if inobj.kind_of?(String)
        parse_string( inobj )
    elsif inobj.respond_to?(:each)
        parse_enumerable( inobj )
    end
  end

  def each
    return unless @segments
    @segments.each { |s| yield s }
  end

  def to_s                         
    @segments.join( '\n' )
  end

  def to_hl7
    @segments.join( @segment_delim )
  end

  def to_mllp
  end

  def sequence_segments
    last = nil
    @segments.each do |s|
      if s.kind_of?( last.class ) && s.respond_to?( :set_id )
        if (last.set_id == "" || last.set_id == nil)
          last.set_id = 1
        end
        s.set_id = last.set_id.to_i + 1
      end

      last = s
    end
  end

  private
  def parse_enumerable( inary )
    inary.each do |oary|
      parse_string( oary )
    end
  end

  def parse_string( instr )
    ary = instr.split( segment_delim, -1 )
    generate_segments( ary )
  end

  def generate_segments( ary )
    raise HL7::ParseError.new unless ary.length > 0

    ary.each do |elm|
      seg_parts = elm.split( @element_delim, -1 )
      raise HL7::ParseError.new unless seg_parts && (seg_parts.length > 0)

      seg_name = seg_parts[0]
      begin
        kls = eval("HL7::Message::Segment::%s" % seg_name)
      rescue Exception
        # we don't have an implementation for this segment
        # so lets just preserve the data
        kls = HL7::Message::Segment::Default
      end
      new_seg = kls.new( elm )
      @segments << new_seg

      # we want to allow segment lookup by name
      seg_sym = seg_name.to_sym
      @segments_by_name[ seg_sym ] ||= []
      @segments_by_name[ seg_sym ] << new_seg
    end

  end
end                

class HL7::Message::Segment
  attr :element_delim
  attr :item_delim
  attr :segment_weight

  def initialize(raw_segment="")
    @segments_by_name = {}
    @element_delim = '|'
    @field_total = 0

    if (raw_segment.kind_of? Array)
      @elements = raw_segment
    else
      @elements = raw_segment.split( element_delim, -1 )
    end
  end

  def to_info
    "%s: empty segment >> %s" % [ self.class.to_s, @elements.inspect ] 
  end

  def to_s
    @elements.join( @element_delim )
  end

  def method_missing( sym, *args, &blk )
    base_str = sym.to_s.gsub( "=", "" )
    base_sym = base_str.to_sym

    if self.class.field_ids.include?( base_sym )
      # base_sym is ok, let's move on
    elsif /e([0-9]+)/.match( base_str )
      # base_sym should actually be $1, since we're going by
      # element id number
      base_sym = $1.to_i
    else
      super.method_missing( sym, args, blk )  
    end

    if sym.to_s.include?( "=" )
      write_field( base_sym, args )
    else
      read_field( base_sym )
    end
  end

  def <=>( other )
    return nil unless other.kind_of?(HL7::Message::Segment)

    diff = self.weight - other.weight
    return -1 if diff > 0
    return 1 if diff < 0
    return 0
  end
  
  def weight
    self.class.weight
  end

  private
  def self.singleton
    class << self; self end
  end

  def self.segment_weight( my_weight )
    singleton.module_eval do
      @my_weight = my_weight
    end
  end

  def self.weight
    singleton.module_eval do
      return 999 unless @my_weight
      @my_weight
    end
  end

  def self.add_field( options={} )
    options = {:name => :id, :idx =>0}.merge!( options )
    name = options[:name]
    namesym = name.to_sym
    
    singleton.module_eval do
      @field_ids ||= {}
      @field_ids[ namesym ] = options[:idx].to_i - 1 
    end
    eval <<-END
      def #{name}()
        read_field( :#{namesym} )
      end

      def #{name}=(value)
        write_field( :#{namesym}, value ) 
      end
    END

  end

  def self.field_ids
    singleton.module_eval do
      @field_ids
    end
  end

  def read_field( name )
    unless name.kind_of?( Fixnum )
      idx = self.class.field_ids[ name ] 
    else
      idx = name
    end
    return nil if (idx >= @elements.length) 

    ret = @elements[ idx ]
    ret = ret.first if (ret.kind_of?(Array) && ret.length == 1)
    ret
  end

  def write_field( name, value )
    unless name.kind_of?( Fixnum )
      idx = self.class.field_ids[ name ] 
    else
      idx = name
    end

    if (idx >= @elements.length)
      # make some space for the incoming field, missing items are assumed to
      # be empty, so this is valid per the spec -mg
      missing = ("," * (idx-@elements.length)).split(',',-1)
      @elements += missing
    end


    @elements[ idx ] = value.to_s
  end

  @elements = []
  @field_ids = {}


end

def Date.from_hl7( hl7_date )
end

def Date.to_hl7_short( ruby_date )
end

def Date.to_hl7_med( ruby_date )
end

def Date.to_hl7_long( ruby_date )
end

class HL7::Message::Segment::MSH < HL7::Message::Segment
  segment_weight -1 # the msh should always start a message
  add_field :name=>:field_sep, :idx=>1
  add_field :name=>:enc_chars, :idx=>2
  add_field :name=>:sending_app, :idx=>3
  add_field :name=>:sending_facility, :idx=>4
  add_field :name=>:recv_app, :idx=>5
  add_field :name=>:recv_facility, :idx=>6
  add_field :name=>:time, :idx=>7
  add_field :name=>:security, :idx=>8
  add_field :name=>:message_type, :idx=>9
  add_field :name=>:message_control_id, :idx=>10
  add_field :name=>:processing_id, :idx=>11
  add_field :name=>:version_id, :idx=>12
  add_field :name=>:seq, :idx=>13
  add_field :name=>:continue_ptr, :idx=>14
  add_field :name=>:accept_ack_type, :idx=>15
  add_field :name=>:app_ack_type, :idx=>16
  add_field :name=>:country_code, :idx=>17
  add_field :name=>:charset, :idx=>18

end

class HL7::Message::Segment::MSA < HL7::Message::Segment
  segment_weight 0 # should occur after the msh segment
  add_field :name=>:sid, :idx=>1
  add_field :name=>:ack_code, :idx=>2
  add_field :name=>:control_id, :idx=>3
  add_field :name=>:text, :idx=>4
  add_field :name=>:expected_seq, :idx=>5
  add_field :name=>:delayed_ack_type, :idx=>6
  add_field :name=>:error_cond, :idx=>7
end

class HL7::Message::Segment::EVN < HL7::Message::Segment
end

class HL7::Message::Segment::PID < HL7::Message::Segment
  add_field :name=>:set_id, :idx=>1
  add_field :name=>:patient_id, :idx=>2
  add_field :name=>:patient_id_list, :idx=>3
  add_field :name=>:alt_patient_id, :idx=>4
  add_field :name=>:patient_name, :idx=>5
  add_field :name=>:mother_maiden_name, :idx=>6
  add_field :name=>:patient_dob, :idx=>7
end

class HL7::Message::Segment::PV1 < HL7::Message::Segment
end

class HL7::Message::Segment::NTE < HL7::Message::Segment
  segment_weight 4
  add_field :name=>:set_id, :idx=>1
  add_field :name=>:source, :idx=>2
  add_field :name=>:comment, :idx=>3
  add_field :name=>:comment_type, :idx=>4
end

class HL7::Message::Segment::ORU < HL7::Message::Segment
end

class HL7::Message::Segment::Default < HL7::Message::Segment
  # all segments have an order-id 
  add_field :name=>:sid, :idx=> 1
end

# vim:tw=78:sw=2:ts=2:et:fdm=marker: