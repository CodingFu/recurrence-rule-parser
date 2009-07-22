require 'rubygems'
require 'runt'

class RruleParser
  VERSION = '1.0.0'
  
  DAYS = {
    "SU" => Runt::Sunday,
    "MO" => Runt::Monday,
    "TU" => Runt::Tuesday,
    "WE" => Runt::Wednesday,
    "TH" => Runt::Thursday,
    "FR" => Runt::Friday,
    "SA" => Runt::Saturday,
  }
  
  DAY_NAMES = {
    "SU" => 'Sunday',
    "MO" => 'Monday',
    "TU" => 'Tuesday',
    "WE" => 'Wednesday',
    "TH" => 'Thursday',
    "FR" => 'Friday',
    "SA" => 'Saturday',
  }
  
  ADVERB_MAP = {
    "DAILY"   => "DAY",
    "WEEKLY"  => "WEEK",
    "MONTHLY" => "MONTH",
    "YEARLY"  => "YEAR"
  }
  
  attr_accessor :event
  attr_accessor :rules, :exceptions
    
  def initialize(event)
    self.event = event
    self.setup
  end
  
  def setup
    @expressions      = []
    @count            = 0
    self.rules        = {}
    self.parse_rules
    self.parse_exceptions
    parse_count
    self
  end
  
  alias :reload :setup
  
  # Parse rules, output temporal expressions
  def expressions        
    @expressions = []
    @expressions << parse_frequency_and_interval
    @expressions << send(:"parse_#{self.rules[:freq].downcase}") if self.rules[:freq]
    @expressions << parse_start
    @expressions << parse_until
    @expressions.compact!
    @expressions
  end
  
  def expression
    self.expressions.inject {|m, v| v & m}
  end
  
  def frequency
    self.rules[:freq]
  end
  
  def interval
    self.rules[:interval].to_i || 1
  end
  
  # Accepts a range of dates and outputs an array of dates matching the temporal expression.
  def dates(range)
    dates = []
    
    if @count <= 0
      dates << self.expression.dates(range)
    else
      temp_range = (self.event.start.send :to_date)..(range.last)
      temp_dates = self.expression.dates(temp_range, @count)
      dates << temp_dates.select do |date|
        range.include?(date)
      end
    end
  
    # Put original date back in if recurrence rule doesn't define it.
    start_date = self.event.start.send(:to_date)
    dates << start_date if range.include?(start_date)
    
    dates.flatten.uniq - self.exceptions
  end
  
  def self.parse_rules(rrules)
    rules = {}
    
    rrules.each do |rule|
      pairs = rule.split(";")
      pairs.each do |pair|
        array = pair.split('=')
        rules[array[0].downcase.to_sym] = array[1]
      end
    end

    # Parse comma separated lists.
    rules.each do |key, rule|
      if rule =~ /,/
        rules[key] = rule.split(',')
      end
    end

    # Override rules to_s
    rules.instance_eval do
      def to_s
        # Enforce order: FREQ, INTERVAL, BYDAY
        ordered = [:freq, :interval, :byday]
        ordered_values = ordered.map do |key|
          "#{key.to_s.upcase}=#{self[key].map.join(',')}" if self[key]
        end
        
        unordered_values = self.map do |key, value|
          "#{key.to_s.upcase}=#{value.map.join(',')}" unless ordered.include?(key)
        end
        
        all_values = (ordered_values + unordered_values).compact.join(';')
      end
    end
    
    rules
  end
  
  def to_s
    clauses = [freq_interval_clause, byday_clause, until_clause].compact.join(' ')
    
    if clauses.blank?
      'Never'
    else
      "Every #{clauses}"
    end
  end
  
  protected
  
  def parse_rules
    self.rules = RruleParser.parse_rules(self.event.recurrence_rules)
  end
  
  def parse_exceptions
    # Exception dates are a bit of a misnomer. They should be stored
    # as Times instead. Right now we are going to assume all exdates
    # are stored as UTC. We can support time zone conversion later.
    self.exceptions = self.event.exception_dates.map do |exception_time|
      Time.parse(exception_time)
    end
  end
  
  def parse_start
    start_date = Date.civil(self.event.start.year, self.event.start.month, self.event.start.day) - 1
    Runt::AfterTE.new(start_date)
  end
  
  def parse_frequency_and_interval
    if frequency
      unless frequency == 'DAILY'
        Runt::EveryTE.new(self.event.start, interval, Runt::DPrecision.const_get(ADVERB_MAP[frequency]))
      end
    end
  end
  
  def parse_daily
    Runt::DayIntervalTE.new(self.event.start, interval)
  end
  
  def parse_weekly
    if self.rules[:byday]
      self.rules[:byday].map { |day| parse_byday(day) }.inject do |m, expr|
        m | expr
      end
    else
      # Make the event recur on the day of the original event.
      Runt::DIWeek.new(self.event.start.wday)
    end
  end
  
  def parse_monthly
    if self.rules[:byday]
      self.rules[:byday].map do |day_string|
        parse_byday(day_string)
      end.inject {|m, expr| m | expr}
    elsif self.rules[:bymonthday]
      self.rules[:bymonthday].map { |day| Runt::REMonth.new(day.to_i) }.inject do |m, expr|
        m | expr
      end
    else
      Runt::REMonth.new(self.event.start.day, self.event.start.day)
    end
  end
  
  def parse_yearly
    expressions = []

    if self.rules[:bymonth]
      expressions << self.rules[:bymonth].map { |month| Runt::REYear.new(month.to_i) }.inject do |m, expr|
        m | expr
      end
    else
      expressions << Runt::REYear.new(self.event.start.month)
    end
    
    if self.rules[:byday]
      expressions << self.rules[:byday].map { |day_string| parse_byday(day_string) }.inject {|m, v| m | v}
    else
      expressions << Runt::REMonth.new(self.event.start.day)
    end
    
    expressions.inject {|m, expr| m & expr}
  end
  
  def parse_until
    if self.rules[:until]
      Runt::BeforeTE.new(Date.parse(self.rules[:until]))
    end
  end
  
  def parse_count
    @count = self.rules[:count].to_i if self.rules[:count]
  end
  
  def parse_byday(day_string)
    # BYDAY rules can be in one of two formats: 2TU (2nd Tuesday), or TU (every Tuesday)
    if day_string =~ /\d/
      day_index         = day_string.to_i
      day               = DAYS[day_string.gsub(day_index.to_s, '')] # Why is abbreviation such a long word?
      Runt::DIMonth.new(day_index, day)
    else
      Runt::DIWeek.new(RruleParser::DAYS[day_string])
    end
  end
  
  def pluralize(count, word)
    if count == 1
      word
    else
      "#{count} #{word}s"
    end
  end
  
  def freq_interval_clause
    return nil unless rules[:freq] && rules[:interval]
    
    pluralize(rules[:interval].to_i, ADVERB_MAP[rules[:freq]].downcase)
  end
  
  def byday_clause
    return nil unless rules[:byday]
    
    days = rules[:byday].map { |abbr| DAY_NAMES[abbr] }
    
    output =
      case days.length
      when 0
        return nil
      when 1
        days.first
      when 2
        days.join(' and ')
      else
        last_day    = days.pop
        other_days  = days.join(', ')
        [other_days, last_day].join(', and ')
      end
      
    "on #{output}" if output
  end
  
  def until_clause
    return nil unless rules[:until]
    
    time = Time.zone.parse rules[:until]
    
    "until #{time.strftime("%B %d, %Y")}"
  end
end