module Remi::Testing::BusinessRules
  using Remi::Refinements::Symbolizer

  def self.csv_opt_map
    {
      'tab'             => "\t",
      'comma'           => ',',
      'pipe'            => '|',
      'double quote'    => '"',
      'single quote'    => "'",
      'windows'         => "\r\n",
      'unix'            => "\n",
      'windows or unix' => :auto,
      'null character'  => 0.chr,
    }
  end


  module ParseFormula
    extend self

    def is_formula?(arg)
      !base_regex.match(arg).nil?
    end

    def base_regex
      @base_regex ||= /\*(.*)\*/
    end

    def formulas
      @formulas ||= RegexSieve.new({
        /\*now(|:[^*]+)\*/i => [:time_reference, :match_now],
        /\*(today|yesterday|tomorrow)(|:[^*]+)\*/i => [:date_reference, :match_single_day],
        /\*(this|last|previous|next) (day|month|year|week)(|:[^*]+)\*/i => [:date_reference, :match_single_unit],
        /\*(\d+)\s(day|days|month|months|year|years|week|weeks) (ago|from now)(|:[^*]+)\*/i => [:date_reference, :match_multiple]
      })
    end

    def parse(form)
      return form unless is_formula?(form)

      form_opt = formulas[form, :match]
      raise "Unknown formula #{form}" unless form_opt[:match]

      to_replace = form.match(base_regex)[0]
      replace_with = if form_opt[:value][0] == :date_reference
        date_reference(form_opt[:value][1], form_opt[:match])
      elsif form_opt[:value][0] == :time_reference
        time_reference(form_opt[:value][1], form_opt[:match])
      else
        to_replace
      end

      form.gsub(to_replace, replace_with)
    end

    def time_reference(formula, captured)
      parsed = self.send("time_reference_#{formula}", *captured)
      Time.current.send("#{parsed[:unit]}_#{parsed[:direction]}", parsed[:quantity]).strftime(parsed[:format])
    end

    def date_reference(formula, captured)
      parsed = self.send("date_reference_#{formula}", *captured)
      Date.current.send("#{parsed[:unit]}_#{parsed[:direction]}", parsed[:quantity]).strftime(parsed[:format])
    end

    def parse_colon_date_format(str)
      str.blank? ? '%Y-%m-%d' : str.slice(1..-1).strip
    end

    def parse_colon_time_format(str)
      str.blank? ? '%Y-%m-%d %H:%M:%S' : str.slice(1..-1).strip
    end

    def time_reference_match_now(form, format=nil)
      {
        quantity: 0,
        unit: 'days',
        direction: 'ago',
        format: parse_colon_time_format(format)
      }
    end

    def date_reference_match_single_day(form, direction, format=nil)
      {
        quantity: direction.downcase == 'today' ? 0 : 1,
        unit: 'days',
        direction: { 'today' => 'ago', 'yesterday' => 'ago', 'tomorrow' => 'since' }[direction.downcase],
        format: parse_colon_date_format(format)
      }
    end

    def date_reference_match_single_unit(form, direction, unit, format=nil)
      {
        quantity: direction.downcase == 'this' ? 0 : 1,
        unit: unit.downcase.pluralize,
        direction: { 'this' => 'ago', 'last' => 'ago', 'previous' => 'ago', 'next' => 'since' }[direction.downcase],
        format: parse_colon_date_format(format)
      }
    end

    def date_reference_match_multiple(form, quantity, unit, direction, format=nil)
      {
        quantity: quantity.to_i,
        unit: unit.downcase.pluralize,
        direction: { 'ago' => 'ago', 'from now' => 'since' }[direction.downcase],
        format: parse_colon_date_format(format)
      }
    end
  end

  class Tester

    def initialize(job_name)
      job_class_name = "#{job_name.gsub(/\s/,'')}Job"
      require_job_file(job_class_name)
      @job = Object.const_get(job_class_name).new

      @job_sources = DataSubjectCollection.new
      @job_targets = DataSubjectCollection.new

      @sources = DataSubjectCollection.new
      @targets = DataSubjectCollection.new
      @examples = DataExampleCollection.new
    end

    attr_reader :job
    attr_reader :job_sources
    attr_reader :job_targets
    attr_reader :sources
    attr_reader :targets
    attr_reader :examples

    def require_job_file(job_class_name)
      job_file = Dir["#{Remi::Settings.jobs_dir}/**/*_job.rb"].map do |fname|
        fname if File.basename(fname) == "#{job_class_name.underscore}.rb"
      end.compact.pop
      require job_file
    end

    def add_job_source(name)
      raise "Unknown source #{name} for job" unless @job.methods.include? name.symbolize
      @job_sources.add_subject(name, @job.send(name.symbolize))
      @job.send(name.symbolize).empty_stub_df
    end

    def add_job_target(name)
      raise "Unknown target #{name} for job" unless @job.methods.include? name.symbolize
      @job_targets.add_subject(name, @job.send(name.symbolize))
    end

    def set_job_parameter(name, value)
      @job.params[name.to_sym] = value
    end

    def add_source(name)
      @sources.add_subject(name, @job.send(name.symbolize))
    end

    def source
      @sources.only
    end

    def add_target(name)
      @targets.add_subject(name, @job.send(name.symbolize))
    end

    def target
      @targets.only
    end


    def add_example(example_name, example_table)
      @examples.add_example(example_name, example_table)
    end

    def run_transforms
      @job.execute(:transforms)
    end
  end




  class DataSubjectCollection
    include Enumerable

    def initialize
      @subjects = {}
    end

    def [](subject_name)
      @subjects[subject_name]
    end

    def each(&block)
      @subjects.each &block
    end

    def keys
      @subjects.keys
    end

    def parse_full_field(full_field_name, multi: false)
      if full_field_name.include? ':'
        full_field_name.split(':').map(&:strip)
      elsif multi
        [@subjects.keys, full_field_name]
      else
        raise "Multiple subjects defined: #{keys}" unless @subjects.size == 1
        [@subjects.keys.first, full_field_name]
      end
    end

    def add_subject(subject_name, subject)
      @subjects[subject_name] ||= DataSubject.new(subject_name, subject)
    end

    def add_field(full_field_name)
      subject_names, field_name = parse_full_field(full_field_name, multi: true)
      Array(subject_names).each do |subject_name|
        @subjects[subject_name].add_field(field_name)
      end
    end

    def only
      raise "Multiple subjects defined: #{keys}" unless @subjects.size == 1
      @subjects.values.first
    end

    def fields
      Enumerator.new do |enum|
        @subjects.each do |subject_name, subject|
          subject.fields.each { |field_name, field| enum << field }
        end
      end
    end

    def full_field_names
      @subjects.map do |subject_name, subject|
        subject.fields.map { |field_name, field| "#{field.full_name}" }
      end.flatten
    end

    def size
      @subjects.size
    end

    def total_size
      @subjects.reduce(0) { |sum, (name, subject)| sum += subject.size }
    end
  end


  class DataSubject
    def initialize(name, subject)
      @name = name
      @data_subject = subject
      @fields = DataFieldCollection.new

      stub_data
    end

    attr_reader :name

    def add_field(field_name)
      @fields.add_field(self, field_name)
    end

    def field
      @fields.only
    end

    def fields
      @fields
    end

    def size
      data_subject.df.size
    end

    def data_subject
      @data_subject.dsl_eval
    end

    # Public: Converts the data subject to a hash where the keys are the table
    # columns and the values are an array for the value of column for each row.
    def column_hash
      data_subject.df.to_h.reduce({}) do |h, (k,v)|
        h[k.symbolize] = v.to_a
        h
      end
    end

    # Would like to have this return a new DataSubject and not a dataframe.
    # Need more robust duping to make that feasible.
    # Don't use results for anything more than size.
    def where(field_name, operation)
      data_subject.df.where(data_subject.df[field_name.symbolize(data_subject.field_symbolizer)].recode { |v| operation.call(v) })
    end

    def where_is(field_name, value)
      where(field_name, ->(v) { v == value })
    end

    def where_lt(field_name, value)
      where(field_name, ->(v) { v.to_f < value.to_f })
    end

    def where_gt(field_name, value)
      where(field_name, ->(v) { v.to_f > value.to_f })
    end

    def where_between(field_name, low_value, high_value)
      where(field_name, ->(v) { v.to_f.between?(low_value.to_f, high_value.to_f) })
    end

    def where_in(field_name, list)
      list_array = list.split(',').map { |v| v.strip }
      where(field_name, ->(v) { list_array.include?(v) })
    end


    def stub_data
      data_subject.stub_df if data_subject.respond_to? :stub_df
    end

    def example_to_df(example)
      df = example.to_df(data_subject.df.row[0].to_h, field_symbolizer: data_subject.field_symbolizer)
      data_subject.fields.each do |vector, metadata|
        if metadata[:type] == :json
          df[vector].recode! { |v| JSON.parse(v) rescue v }
        end
      end
      df
    end

    def stub_data_with(example)
      stub_data
      data_subject.df = example_to_df(example)
    end

    def append_data_with(example)
      data_subject.df = data_subject.df.concat example_to_df(example)
    end


    def replicate_rows(n_rows)
      replicated_df = Daru::DataFrame.new([], order: data_subject.df.vectors.to_a)
      data_subject.df.each do |vector|
        replicated_df[vector.name] = vector.to_a * n_rows
      end
      data_subject.df = replicated_df
    end

    def cumulative_dist_from_freq_table(table, freq_field: 'frequency')
      cumulative_dist = {}
      freq_total = 0
      table.hashes.each do |row|
        low = freq_total
        high = freq_total + row[freq_field].to_f
        freq_total = high
        cumulative_dist[(low...high)] =   row.tap { |r| r.delete(freq_field) }
      end
      cumulative_dist
    end

    def generate_values_from_cumulative_dist(n_records, cumulative_dist)
      # Use the same key for reproducible tests
      psuedorand = Random.new(3856382695386)

      1.upto(n_records).reduce({}) do |h, idx|
        r = psuedorand.rand
        row_as_hash = cumulative_dist.select { |range| range.include? r }.values.first
        row_as_hash.each do |field_name, value|
          h[field_name] ||= []
          h[field_name] << value
        end
        h
      end
    end

    def distribute_values(table)
      cumulative_dist = cumulative_dist_from_freq_table(table)
      generated_data = generate_values_from_cumulative_dist(data_subject.df.size, cumulative_dist)

      generated_data.each do |field_name, data_array|
        vector_name = fields[field_name].field_name
        data_subject.df[vector_name] = Daru::Vector.new(data_array, index: data_subject.df.index)
      end
    end

    def freq_by(*field_names)
      data_subject.df.group_by(field_names).size * 1.0 / data_subject.df.size
    end

    def unique_integer_field(field_name)
      vector_name = fields[field_name].field_name
      i = 0
      data_subject.df[vector_name].recode! { |v| i += 1 }
    end
  end


  class DataFieldCollection
    include Enumerable

    def initialize
      @fields = {}
    end

    def [](field_name)
      @fields[field_name]
    end

    def each(&block)
      @fields.each(&block)
    end

    def keys
      @fields.keys
    end

    def names
      @fields.values.map(&:name)
    end

    def field_names
      @fields.values.map(&:field_name)
    end

    def add_field(subject, field_name)
      raise "Attempting to add a field with the same name but different subject - #{subject.name}: #{field_name}" if @fields.include?(field_name) && @fields[field_name].subject.name != subject.name
      @fields[field_name] = DataField.new(subject, field_name) unless @fields.include? field_name
    end

    def only
      raise "Multiple subject fields defined: #{keys}" if @fields.size > 1
      @fields.values.first
    end

    # All values get tested as strings
    def values
      @fields.map { |field_name, field| field.values.map(&:to_s) }.transpose
    end
  end


  class DataField
    def initialize(subject, name)
      @subject = subject
      @name = name
      @field_name = name.symbolize(subject.data_subject.field_symbolizer)
    end

    attr_reader :name
    attr_reader :field_name
    attr_reader :subject

    def full_name
      "#{@subject.name}: #{@name}"
    end

    def metadata
      @subject.data_subject.fields[@field_name]
    end

    def vector
      @subject.data_subject.df[@field_name]
    end

    def value
      v = vector.to_a.uniq
      raise "Multiple unique values found in subject data for field #{@field_name}" if v.size > 1
      v.first
    end

    def values
      vector.to_a.map(&:to_s)
    end

    def value=(arg)
      typed_arg = if metadata[:type] == :json
        JSON.parse(arg)
      else
        arg
      end

      vector.recode! { |_v| typed_arg }
    end
  end


  class DataExampleCollection
    include Enumerable

    def initialize
      @examples = {}
    end

    def [](example_name)
      @examples[example_name]
    end

    def each(&block)
      @examples.each(&block)
    end

    def keys
      @examples.keys
    end

    def add_example(example_name, example_table)
      @examples[example_name] = DataExample.new(example_table) unless @examples.include? example_name
    end
  end


  class DataExample
    def initialize(table)
      @table = table
    end

    def parse_formula(value)
      parsed_value = ParseFormula.parse(value)
      case parsed_value
      when '\nil'
        nil
      else
        parsed_value
      end
    end

    def to_df(seed_hash, field_symbolizer:)
      table_headers = @table.headers.map { |h| h.symbolize(field_symbolizer) }
      df = Daru::DataFrame.new([], order: seed_hash.keys | table_headers)
      @table.hashes.each do |example_row|
        example_row_sym = example_row.reduce({}) do |h, (k,v)|
          h[k.symbolize(field_symbolizer)] = parse_formula(v)
          h
        end
        df.add_row(seed_hash.merge(example_row_sym))
      end
      df
    end

    # Public: Converts a Cucumber::Ast::Table to a hash where the keys are the table
    # columns and the values are an array for the value of column for each row.
    def column_hash
      @table.hashes.reduce({}) do |h, row|
        row.each do |k,v|
          (h[k.symbolize] ||= []) << parse_formula(v)
        end
        h
      end
    end
  end
end
