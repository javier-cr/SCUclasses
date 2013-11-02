task :update_sections => :environment do
  require 'rest-client'
  require 'nokogiri'

  start = Time.now
  print(Section.count, " existing sections\n")
  newsections = 0

  # get section list
  url = 'http://www.scu.edu/courseavail/search/index.cfm?fuseAction=search&StartRow=1&MaxRow=4000&acad_career=all&school=&subject=&catalog_num=&instructor_name1=&days1=&start_time1=&start_time2=23&header=yes&footer=yes&term=' + TERM
  res = RestClient::Request.execute(:method => :get, :url => url, :timeout => 200)
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
          time_start = parse_time(times[1])
          time_end = parse_time(times[2])
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
        newsections += 1
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
      thissection.save
      thissection.touch
    end
  end

  # remove sections that don't exist anymore
  todelete = Section.where('updated_at < ?', Time.now - 100*60) # 100 mintue grace period
  print(todelete.length, " sections deleted\n")
  todelete.destroy_all

  print(Section.count, " sections updated\n")
  print(newsections, " new sections\n")

  if newsections > 0 || Time.now.hour%4 == 0 || true
    Rake::Task['update_sections_details'].execute
  end

  print("update took ", ((Time.now - start)/60).round(2), " minutes\n")
end

def parse_time(time)
  time = /(\d{2}):(\d{2})\s([APM]{2})/.match(time)
  hours = time[1].to_i * 100
  minutes = time[2].to_i
  ampm = time[3]

  time = hours + minutes + ((ampm=='PM' && hours<1200) ? 1200 : 0)
  return time
end





task :update_sections_details => :environment do
  require 'rest-client'
  require 'nokogiri'
  require 'ruby-progressbar'

  sections = Section.all

  progress = ProgressBar.create(
      :title => 'section details',
      :total => sections.length,
      :format => '%t: |%B| %P%%, %e'
  )

  sections.each do |section|
    # get section details
    res = RestClient.get('http://www.scu.edu/courseavail/class/?fuseaction=details&class_nbr=' + section.id.to_s + '&term=' + TERM)
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

    progress.increment
  end

  print("done!\n")
end
