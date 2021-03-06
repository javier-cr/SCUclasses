require 'rest-client'
require 'nokogiri'
require 'ruby-progressbar'
require 'scuclasses_platform/util'


COURSEAVAIL_URL = 'https://legacy.scu.edu/courseavail'
current_term = nil


task :update => :environment do
  start = Time.now

  Rake::Task['update_core_keys'].execute
  Rake::Task['update_terms'].execute
  throw 'no terms' if Term.count < 1

  terms = Term.where(name: ENV['SCUCLASSES_TERM'])
  if terms.length == 0
    puts 'using default term'
    terms = Term.where(default: true)
  else
    puts 'using SCUCLASSES_TERM environment variable override'
  end

  terms.each do |term|
    puts "updating term: #{term.name}"
    current_term = term

    # update sections
    Rake::Task['update_sections'].execute

    # only update section details twice a day at 7am/pm
    # section data updated daily at 6am/pm
    # remaining seats updated every 2 minutes
    hour = Time.now.hour
    if hour == 7 || hour == 12+7
      puts 'updating section details'

      sections = Section.all
      progress = ProgressBar.create(
        title: 'section details',
        total: sections.length,
        format: '%t: |%B| %P%%, %e',
      )

      sections.each do |section|
        update_section_details section, current_term
        progress.increment
      end
    else
      puts 'skipping section details update'
    end

    puts "\n"
  end

  puts "update took #{((Time.now - start)/60).round(2)} minutes"
end


task :update_terms => :environment do
  # get courseavail landing page
  res = RestClient.get(COURSEAVAIL_URL)
  res = Nokogiri.HTML(res)

  # save terms to database
  res.css('#term option').each do |term|
    name = term.text.strip
    number = term.attribute('value').value.to_i

    newterm = Term.where(number: number).first_or_initialize
    newterm.name = name
    newterm.number = number

    if ENV['SCUCLASSES_TERM']
      newterm.default = newterm.name == ENV['SCUCLASSES_TERM']
    else
      newterm.default = term.attribute('selected') ? true : false
    end

    newterm.save
    newterm.touch

    # remove terms that haven't been visible for 5 days
    Term.where('updated_at < ?', Time.now - 5.days).destroy_all
  end

  puts "\n"
  puts "total of #{Term.count} terms: #{Term.all.map{|t| t.name}.join(', ')}"
  puts "default term is #{Term.find_by_default(true).name}\n\n"
end





task :update_sections => :environment do
  puts "#{Section.where(term_id: current_term.id).count} existing sections"
  newsections = []

  # get section list
  url = "#{COURSEAVAIL_URL}/search/index.cfm?fuseAction=search&StartRow=1&MaxRow=10000&acad_career=all&school=&subject=&catalog_num=&instructor_name1=&days1=&start_time1=&start_time2=23&header=yes&footer=yes&term=#{current_term.number}"
  res = RestClient::Request.execute(method: :get, url: url, timeout: 200)
  res = Nokogiri.HTML(res)

  # parse, set, and save section list
  res.css('#zebra tr').each do |section|
    if section.css('td').length == 8
      id = section.css('td')[1].text.to_i

      # parse date and time
      scheduletext = section.css('td')[4].text.strip

      # check that schedule is defined
      if scheduletext == '-'
        days = ''
        time_start = 0
        time_end = 0
      else
        days = (a = /([MTWRFSU]+)\s/.match(scheduletext)) ? a[1] : nil
        times = /(\d{2}:\d{2}\s[APM]{2})-(\d{2}:\d{2}\s[APM]{2})/.match(scheduletext)

        # check that time is well-formed
        if days != nil && times != nil
          time_start = Util.parse_time(times[1])
          time_end = Util.parse_time(times[2])
        else
          days = ''
          time_start = 0
          time_end = 0
        end
      end

      # create new or update existing
      if Section.exists?(id)
        thissection = Section.find(id)
      else
        thissection = Section.new
        newsections.push thissection
      end

      # set section properties
      thissection.id = id
      thissection.name = section.css('td')[0].text.strip
      thissection.fullname = section.css('td')[3].text.strip.gsub(/\s{2,}/, ' ')
      thissection.seats = section.css('td')[7].text.to_i
      thissection.instructors = section.css('td')[6].text.strip
      thissection.days = days
      thissection.time_start = time_start
      thissection.time_end = time_end
      thissection.term_id = current_term.id
      thissection.save
      thissection.touch
    end
  end

  # remove sections that don't exist anymore
  todelete = Section.where('updated_at < ?', Time.now - 2.5*60*60) # 2.5 hour grace period
  puts "#{todelete.length} sections deleted"
  todelete.destroy_all

  puts "#{newsections.count} new sections"

  newsections.each do |section|
    update_section_details section, current_term
    print '.'
  end
  puts "\n" if newsections.length > 0
end






def update_section_details(section, current_term)
  # get section details
  res = RestClient.get("#{COURSEAVAIL_URL}/class/?fuseaction=details&class_nbr=#{section.id.to_s}&term=#{current_term.number}")
  res = Nokogiri.HTML(res)

  # parse section details
  res.css('#page-primary tr').each do |detail|
    detail_name = detail.css('th').text.strip
    value = detail.css('td').text.strip

    if 'Description' == detail.css('th').text.strip
      section.description = value.gsub(/\s{2,}/, ' ')
    end

    if detail_name.match(/2009 Core/)
      section.core = value.scan(/\w{1}_\w+/).join(',')
    end

    if 'Units (min/max)' == detail.css('th').text.strip
      section.units = (units = value.scan(/\d/)[0]) ? units : 0;
    end

    if location = detail.css('td')[4]
      section.location = location.text.strip
    end
  end

  section.save
end





task :update_core_keys => :environment do
  # empty core model
  Core.destroy_all

  # get courseavail landing page
  res = RestClient.get(COURSEAVAIL_URL)
  res = Nokogiri.HTML(res)

  res.css('#newcore option').each do |core_option|
    if core_option.text.length > 0
      core = Core.new
      core.key = core_option.attribute('value').text.strip
      core.name = core_option.text.strip[/^\w+\s\-\s[A-Z]+\s(.+)/, 1].gsub(/PATH/, 'Pathway -')
      core.save
    end
  end
end
