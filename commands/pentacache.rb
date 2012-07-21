# vim: set ts=2 sw=2 et ai ft=ruby:

usage       'pentacache'
summary     'loads the Pentabarf database and stores it as a cache file'
aliases     :pc

require 'ostruct'

module PentaDB
end
module PentaModel
end

class PentabarfCache < ::Nanoc::CLI::CommandRunner

  def run
    start_time = Time.now

    require 'psych'
    YAML::ENGINE.yamler = 'psych'
    require 'active_record'
    require 'fileutils'

    require_site
    conf = site.config.fetch(:pentabarf)
    $cache = conf['cache'] || 'tmp/pentacache'
    $cid = conf.fetch('conference_id')

    begin
      h = conf.fetch('host', 'localhost')
      p = conf.fetch('port', '5432')
      puts "Connecting to Pentabarf database at #{h}:#{p} ..."
      ActiveRecord::Base.establish_connection(
        :adapter => 'postgresql',
        :username => conf.fetch('username'),
        :password => conf.fetch('password'),
        :database => conf.fetch('database'),
        :host => conf.fetch('host', 'localhost'),
        :port => conf.fetch('port', '5432'),
        :schema_search_path => conf.fetch('schema', 'public'),
      )
    end
    begin
      ActiveRecord::Base.connection
    rescue
      raise "Failed to connect to the Pentabarf database"
    end

    FileUtils.mkdir_p($cache) unless File.exists? $cache

    # crawl the current cache directory and keep a tree of all files
    # that are in there in order to detect the files we need to delete
    # after rendering changes; don't bother about directories, as we
    # remove all empty directories at the end of the process
    $cache_tree_before = begin
                           require 'find'
                           r = []
                           Find.find($cache) do |f|
                             r << f unless File.directory? f
                           end
                           r.sort
                         end

    # obviously, we haven't created/updated any files yet
    $cache_tree_after = []

    def yf(file, content)
      time_before = Time.now
      require 'pathname'
      fqf = File.join($cache, file)
      b = Pathname.new(fqf).dirname.to_s
      # don't bother about directories in $cache_tree_after
      FileUtils.mkdir_p(b) unless File.exists? b

      action = if File.exists?(fqf)
                 new_digest = sha(content)
                 old_digest = sha(IO.read(fqf))
                 if new_digest != old_digest
                   :update
                 else
                   :identical
                 end
               else
                 :create
               end

      unless action == :identical
        File.open(fqf, "wb") do |f|
          f.write(content)
        end
      end

      $cache_tree_after << fqf

      Nanoc::CLI::Logger.instance.file(action == :identical ? :low : :high, action, fqf, Time.now - time_before)
    end

    def yc(file, v)
      if v.is_a? OpenStruct
        yf(file, v.to_hash.to_yaml)
      elsif v.respond_to? :attributes
        yf(file, v.attributes.to_yaml)
      else
        yf(file, v.to_yaml)
      end
    end

    puts "Rendering cache to #{$cache}..."
    {
      :Person           => 'persons',
    }.each do |klass, table|
      f = Class.new(OpenStruct) do
        yaml_as "!pentabarf,0/#{table}"
        def self.yamlname=(v)
          @@yamlname = v
        end
        def to_yaml_type
          "!pentabarf,0/#{@@yamlname}"
        end
        def to_hash
          h = {}
          @table.each do |k,v|
            h[k.to_s] = v
          end
          h
        end
      end
      f.yamlname = table
      PentaModel.const_set klass.to_s, f
      YAML::add_domain_type("pentabarf,0", table) do |type, val|
        f.new(val)
      end
    end

    {
      :Room             => [ 'conference_room',     'rooms',    :conference_room_id,    :cid,       ],
      :ScheduleEvent    => [ 'view_schedule_event', 'events',   :event_id,              :cid, :tr,  ],
      :Conference       => [ 'conference',          'conf',     nil,                    :cid,       ],
      :ConferenceDay    => [ 'conference_day',      'days',     :conference_day_id,     :cid,       ],
      :Track            => [ 'conference_track',    'tracks',   :conference_track_id,   :cid,       ],
      :Person           => 'person',
      :EventPerson      => 'event_person',
      :EventLink        => 'event_link',
      :ConferencePerson => 'conference_person',
      :ConferencePersonLink => 'conference_person_link',
      :PersonImage      => 'person_image',
    }.each do |klass, info|
      if info.is_a? Array and info.size > 1 then
        table = info[0]
        render_dir = info[1]
        render_pk = info[2]
        render_flags = info[3..-1]
      elsif info.is_a? Array
        table = info[0]
        render_dir = nil
      else
        table = info
        render_dir = nil
      end

      c = Class.new(ActiveRecord::Base) do
        yaml_as "!pentabarf,0/#{table}"
        def self.yamlname=(v)
          @@yamlname = v
        end
        def to_yaml_type
          "!pentabarf,0/#{@@yamlname}"
        end
      end
      c.table_name = table
      c.yamlname = table
      PentaDB.const_set klass.to_s, c

      if render_dir
        q = c.scoped
        q = q.scoped.where(:conference_id => $cid) if render_flags.include? :cid
        q = q.scoped.where(:translated => 'en') if render_flags.include? :tr
        if render_pk
          q.find(:all).each do |r|
            file = File.join(render_dir, r.send(render_pk).to_s)
            yc(file, r)
          end
        else
          file = render_dir
          yc(file, q.find(:first))
        end
      end
    end

    # It's all a bit more complicated for the person thing, needs to be done manually
    # to avoid pulling all the person records from all the previous years too, or even
    # the ones that are not confirmed nor speakers, which we're not interested in at
    # all for rendering the schedule.
    #
    # In order to make this a little faster, we are going to retrieve all records
    # in memory though, which ought to be faster than doing 400 individual select
    # statements, but we will only export the ones that are relevant.
    #
    # In order to only export the person, schedule_person, event_person and conference_person
    # records that are relevant, we need to start by going through the event records that
    # are for this conference:
    events = PentaDB::ScheduleEvent.where(:conference_id => $cid, :translated => 'en').find(:all)
     
    # From there, we need to retrieve the event_person records for each event to find out
    # which person records and conference_person records are involved.
    # But, here, we can already limit the query to the roles (speakers) and states (confirmed)
    # we're interested in
    event_persons = PentaDB::EventPerson
    .where(:event_role => ['coordinator', 'moderator', 'speaker'])
    .where(:event_role_state => ['confirmed', 'offer'])
    .find(:all)

    # And eventually, we get to the list of person and conference_person records.
    # We are also converting the Person records to PentaModel::Person objects, which
    # are OpenStruct with a custom to_hash method which makes the output suitable
    # for to_yaml (and compliant with the other exported objects).
    # At the same time, we are going to only copy certain attributes into the
    # PentaModel::Person objects, as we don't even want to export things link
    # people's bank account (we don't need it on the website, and we want to be able
    # to make the exported transient data public).
    persons = PentaDB::Person.find(:all).map do |db|
      h = {}
      [:person_id, :title, :gender, :first_name, :last_name, :public_name, :nickname].each do |a|
        h[a] = db.send(a)
      end
      PentaModel::Person.new(h)
    end

    conference_persons = PentaDB::ConferencePerson.where(:conference_id => $cid).find(:all)
    conference_person_links = PentaDB::ConferencePersonLink.find(:all)
    conference_person_links_by_id = {}
    conference_person_links.each{|l| conference_person_links_by_id[l.conference_person_id] = []}
    conference_person_links.each{|l| conference_person_links_by_id[l.conference_person_id] << l}

    # Now, let's filter them out in order to export only the ones we'll need, as
    # explained above, but in order to make that a little faster too, we'll sacrifice
    # a bit of memory to build some hashes, as we'll access event_persons, persons
    # and conference_persons by their respective id
    persons_by_person_id = {}
    persons.each{|p| persons_by_person_id[p.person_id] = p}

    conference_persons_by_person_id = {}
    conference_persons.each{|cp| conference_persons_by_person_id[cp.person_id] = cp}

    event_persons_by_event_id = {}
    event_persons.each{|ep| event_persons_by_event_id[ep.event_id] = []}
    event_persons.each{|ep| event_persons_by_event_id[ep.event_id] << ep}

    # faster to fetch them all and filter them out later
    event_links = begin
                    event_by_id = {}
                    events.each{|e| event_by_id[e.event_id] = e}
                    links = {}
                    PentaDB::EventLink.find(:all).each do |link|
                      links[link.event_id] = [] unless links.has_key? link.event_id
                      links[link.event_id] << link
                    end
                    links
                  end

    # Now let's pick out the ones we are interested in and export those:
    events.each do |e|
      # Cautious here: it's possible that we don't have any event_person records
      # for this event, when no persons have been assigned to an event and hence
      # apply the null pattern and fall back to an empty array when we can't find
      # anything in event_persons_by_event_id for that event:
      event_persons_by_event_id.fetch(e.event_id, []).each do |ep|
        # let's already export the event_person
        yc(File.join('event_persons', ep.event_person_id.to_s), ep)

        # now let's retrieve the person
        person = persons_by_person_id[ep.person_id]
        raise "event #{e.event_id} references a person #{ep.person_id} which doesn't exist" unless person

        # as well as the conference_person, if available
        conference_person = conference_persons_by_person_id[person.person_id]
        # decorate person with the fields of its conference_person, if applicable
        if conference_person
          [:abstract, :description].each do |attr|
            person.send(attr.to_s.concat("=").intern, conference_person.send(attr.to_s))
          end
          # as well as with links
          person.links = conference_person_links_by_id.fetch(conference_person.conference_person_id, []).map{|l| l.attributes}
        end

        # and export it
        yc(File.join('persons', person.person_id.to_s), person)

        # as well as that person's photo, if available
        PentaDB::PersonImage.where(:public => true, :person_id => person.person_id).find(:all).each do |i|
          extension = case i.mime_type
                      when 'image/png'
                        'png'
                      when 'image/gif'
                        'gif'
                      when 'image/jpeg'
                        'jpg'
                      else
                        raise "unsupported image MIME type \"#{i.mime_type}\" for person #{person.person_id}"
                      end
          filename = File.join('person_images', "#{person.person_id.to_s}.#{extension}")
          content = i.image
          yf(filename, content) unless content.size < 1
        end

      end #event_persons

      #PentaDB::EventLink.where(:event_id => e.event_id).find(:all).each do |link|
      #  yc(File.join('event_links', link.event_link_id.to_s), link)
      #end
      event_links.fetch(e.event_id, []).each do |link|
        yc(File.join('event_links', link.event_link_id.to_s), link)
      end

    end #events

    # now let's compute which files and dirs we need to remove
    # because they were there before but have not been touched
    # while rendering the cache this time
    begin
      outdated = begin
                   r = []
                   h = {}
                   $cache_tree_after.each{|x| h[x] = 1}
                   $cache_tree_before.each do |f|
                     r << f unless h[f]
                   end
                   r.sort
                 end

      require 'fileutils'
      outdated.each do |f|
        if File.directory? f
          dirs << f
        else
          FileUtils.rm f
          Nanoc::CLI::Logger.instance.file(:high, :delete, f)
        end
      end
    end

    # now crawl for empty directories and remove those too
    begin
      # let's pack this routine into a function of its own,
      # as we need to reiterate the process (see below)
      def find_empty_dirs(dir)
        list = []
        require 'find'
        Find.find(dir) do |d|
          next unless File.directory? d

          # see http://stackoverflow.com/questions/5059156/check-if-directory-is-empty-in-ruby
          if (Dir.entries(d) - %w{ . .. }).empty?
            list << d
          end
        end
        list
      end

      # we have to iterate until we can't find any empty directories any more,
      # as removing one empty directory can yield other empty directories as
      # empty too
      empty_dirs = find_empty_dirs($cache)
      until empty_dirs.empty?
        empty_dirs.each do |d|
          FileUtils.rmdir d
          Nanoc::CLI::Logger.instance.file(:high, :delete, d)
        end
        empty_dirs = find_empty_dirs($cache)
      end
    end

    puts
    puts "Pentabarf cache built in #{format('%.2f', Time.now - start_time)}s."

  end

  private
  def sha(content)
    require 'digest/sha2'
    sha = Digest::SHA256.new
    sha << content
    sha.hexdigest.downcase
  end

end

runner PentabarfCache
