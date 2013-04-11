$LOAD_PATH << './jira4r/lib'

require 'net/http'
require 'open-uri'
require 'jira'
require 'pivotal-tracker'
require 'yaml'

CONFIG_FILE = 'config.yml'
update = false

if File.exist?(CONFIG_FILE)
  $config = YAML::load_file(CONFIG_FILE)
else
  puts "Missing config file: #{CONFIG_FILE}"
  exit 1
end

def already_scheduled?(jira_issue)
  jira_issue.comments.each do |comment|
    return true if comment.body =~ /^Scheduled in Tracker/
  end
  false
end

# Make connection with JIRA
$jira = JIRA::Client.new({ :username => $config['jira_login'],
                           :password => $config['jira_password'],
                           :site =>  "#{$config['jira_uri_scheme']}://#{$config['jira_host']}",
                           :context_path => '',
                           :auth_type => :basic })

# Make connection with Pivotal Tracker
PivotalTracker::Client.token = $config['tracker_token']
$project = PivotalTracker::Project.find($config['tracker_project_id'])
if update
  $project.stories.all.each do |story|
    story.delete
  end
end

# Get all issues for the project from JIRA
puts "Getting all the issues for #{$config['jira_project']}"
jira_project = $jira.Project.find($config['jira_project'])
status_map = { "1" => "unstarted",
               "3" => "started",
               "4" => "rejected",
               "10001" => "delivered",
               "5" => "accepted",
               "6" => "accepted",
               "400" => "finished",
               "401" => "finished" }

type_map = { "1" => "bug",
             "2" => "feature",
             "3" => "feature",
             "4" => "feature",
             "5" => "feature",
             "6" => "feature",
             "7" => "feature",
             "8" => "feature",
             "9" => "feature",
             "10" => "feature" }

def jira_project.issues(start_at)
  response = client.get(client.options[:rest_base_path] + "/search?jql=project%3D'#{key}'&startAt=#{start_at}&expand=changelog")
  json = self.class.parse_json(response.body)
  json['issues'].map do |issue|
    client.Issue.build(issue)
  end
end

start_at =  0
issues = jira_project.issues(start_at)
while issues.count > 0
  issues.each do |issue|
    # Expand the issue with changelog information
    def issue.url_old
      prefix = '/'
      unless self.class.belongs_to_relationships.empty?
        prefix = self.class.belongs_to_relationships.inject(prefix) do |prefix_so_far, relationship|
          prefix_so_far + relationship.to_s + "/" + self.send("#{relationship.to_s}_id") + '/'
        end
      end
      if @attrs['self']
        @attrs['self'].sub(@client.options[:site],'')
      elsif key_value
        self.class.singular_path(client, key_value.to_s, prefix)
      else
        self.class.collection_path(client, prefix)
      end
    end
    def issue.url
      self.url_old + '?expand=changelog'
    end
    issue.fetch

    if not update and already_scheduled?(issue)
      puts "skipping #{issue.key}"
      next
    else
      issue.comments.each do |comment|
        if comment.body =~ /^Scheduled in Tracker/
          begin
            comment.delete
            issue.fetch(:reload=>true)
          rescue Exception=>e
            next
          end
        end
      end
    end

    # Add the issue to pivotal tracker
    puts "Scheduling #{issue.key} with status=#{status_map[issue.status.id]}, type=#{type_map[issue.issuetype.id]}"

    story_args = { :name => issue.summary,
                   :current_state => status_map[issue.status.id],
                   :requested_by => $config['tracker_requester'],
                   :description => issue.description,
                   :story_type => type_map[issue.issuetype.id]}

    if type_map[issue.issuetype.id] == "feature"
      story_args["estimate"] = 1
    end
    if status_map[issue.status.id] == "accepted"
      last_accepted = nil
      issue.changelog['histories'].each do |history|
        history['items'].each do |change|
          if change['to'] == issue.status.id
            last_accepted = history['created']
          end
        end
      end
      if last_accepted
        story_args["accepted_at"] = last_accepted
      end
    end

    story = $project.stories.create(story_args)
    note_text = ""
    if issue.issuetype == "6"
      note_text = "This was an epic from JIRA."
    end
    note_text += "\n\nSubmitted through Jira\n#{$config['jira_uri_scheme']}://#{$config['jira_host']}/browse/#{issue.key}"
    story.notes.create( :text => note_text )

    # Add notes to the story
    puts "Checking for comments"
    issue.comments.each do |comment|
      if comment.body =~ /^Scheduled in Tracker/
        next
      else
        begin
          story.notes.create( :author => comment.author['displayName'],
                              :text => "*Real Author: #{comment.author['displayName']}*\n\n#{comment.body}",
                              :noted_at => comment.created )
        rescue Exception=>e
          story.notes.create( :author => comment.author['displayName'],
                              :text => "*Real Author: #{comment.author['displayName']}*\n\n#{comment.body}",
                              :noted_at => comment.created )
        end
        puts "Added comment by #{comment.author['displayName']}"
      end
    end

    # Add attachments to the story
    puts "Checking for any attachments"
    issue.attachments.each do |attachment|
      # Download the attachment to a temporary file
      puts "Downloading #{attachment.filename}"
      uri = URI.parse(URI.encode("#{$config['jira_uri_scheme']}://#{$config['jira_host']}/secure/attachment/#{attachment.id}/#{attachment.filename}"))
      Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
        req = Net::HTTP::Get.new uri.request_uri
        req.basic_auth $config['jira_login'], $config['jira_password']
        resp = http.request req
        open("/tmp/#{attachment.filename}", "wb") do |file|
          file.write(resp.body)
        end
      end
      attachment_resp = story.upload_attachment( "/tmp/#{attachment.filename}")
      puts "Added attachment: #{attachment.filename}"
    end

    # Add comment to the original JIRA issue
    puts "Adding a comment to the JIRA issue"
    comment = issue.comments.build
    comment.save( :body => "Scheduled in Tracker: #{story.url}" )
  end

  start_at += issues.count
  issues = jira_project.issues(start_at)
end

puts "Successfully imported #{start_at} issues into Pivotal Tracker"
